(import sh)
(import sqlite3)
(import flock)
(import jdn)
(import path)
(import ./build/_hermes :as _hermes)

(var- *store-path* "/hermes")

(defn set-store-path
  [store-path]
  (set *store-path* (path/abspath store-path)))

(defn check-pkg-content
  [base-path content]

  (defn- bad-content
    [msg]
    (return :check-content [:fail msg]))

  (defn- check-hash
    [path expected is-dir]
    (def actual
      (match (string/split ":" expected)
        ["sha256" _]
          (string
            "sha256:"
            (if is-dir
              (_hermes/sha256-dir-hash path)
              (_hermes/sha256-file-hash path)))
        _ 
          (bad-content (string "unsupported hash format - " expected))))
      (unless (= expected actual)
        (bad-content (string "expected " path " to have hash " expected " but got " actual))))

  (defn- unify-dir-content
    [dir-path content &opt st]
    (default st (os/lstat dir-path))
    (unless st
      (bad-content (string "expected content at " dir-path)))
    (unless (struct? content)
      (bad-content (string "expected a directory descriptor struct at " dir-path)))
    (unless (= (st :mode) :directory)
      (bad-content (string "expected a directory at " dir-path)))
    (def ents (os/dir dir-path))
    (unless (= (length ents) (length content))
      (bad-content (string (length ents) " directory entries, expected " (length content) " at " dir-path)))
    (each ent-name ents
      (def ent-path (string dir-path "/" ent-name))
      (def ent-st (os/stat ent-path))
      (def expected-mode (get (content ent-name) :mode :file))
      (def expected-perms (get (content ent-name) :permissions "r--r--r--"))
      (unless (= (ent-st :mode) expected-mode)
        (bad-content (string "expected " expected-mode " at " ent-path)))
      (unless (= (ent-st :permissions) expected-perms)
        (bad-content (string "expected perms " expected-perms " at " ent-path ", got " (ent-st :permissions))))
      (def subcontent (get (content ent-name) :content))
      (case (ent-st :mode)
        :directory
          (if (string? subcontent)
            (check-hash ent-path subcontent true)
            (unify-dir-content ent-path subcontent))
        :link
          (unless (= subcontent (os/readlink ent-path))
            (bad-content (string "link at " ent-path " expected to point to " subcontent)))
        :file
          (do
            (unless (string? subcontent)
              (bad-content (string "content at " ent-path " must be a hash, got: " subcontent)))
            (check-hash ent-path subcontent false))
        (bad-content (string "unexpected mode " (ent-st :mode) " at " ent-path)))))
  
  (prompt :check-content 
    (cond
      (string? content)
        (check-hash base-path content true)
      (struct? content)
        (unify-dir-content base-path content)
      (error (string/format "package content must be a hash or directory description struct")))
    :ok))

(defn- fetch
  [url &opt dest]
  (def url
    (if (or (string/has-prefix? "." url)
            (string/has-prefix? "/" url))
      (do
        (def readlink-bin (comptime (sh/$$_ ["which" "readlink"])))
        (string "file://" (sh/$ [readlink-bin "-f" url])))
      url))
  (default dest (last (string/split "/" url)))
  (def curl-bin (comptime (sh/$$_ ["which" "curl"])))
  (sh/$ [curl-bin "-L" "-o" dest url])
  dest)

(defn- unpack
  [path &opt &keys {
    :dest dest
    :strip nstrip
  }]
  (default dest "./")
  (default nstrip 0)
  (unless (os/stat dest)
    (os/mkdir dest))
  (def tar-bin (comptime (sh/$$_ ["which" "tar"])))
  (sh/$ [tar-bin (string "--strip-components=" nstrip) "-avxf" path "-C" dest]))

(def builder-env (make-env root-env))
(put builder-env 'pkg
  @{:value (fn [&] (error "pkg cannot be invoked inside a builder"))})
(put builder-env 'fetch  @{:value fetch})
(put builder-env 'unpack @{:value unpack})
(put builder-env 'sh/$   @{:value sh/$})
(put builder-env 'sh/$$  @{:value sh/$$})
(put builder-env 'sh/$$_ @{:value sh/$$_})
(put builder-env 'sh/$?  @{:value sh/$?})
(put builder-env '*pkg-noop-build* (fn [&] nil))
(def builder-load-registry (env-lookup builder-env))
(def builder-registry (invert builder-load-registry))

(defn pkg-hash
  [pkg]
  (_hermes/pkg-hash *store-path* builder-registry pkg))

(defn pkg
  [&keys {
    :builder builder
    :name name
    :content content
    :force-refs force-refs
    :extra-refs extra-refs
    :weak-refs weak-refs
  }]
  (_hermes/pkg builder name content force-refs extra-refs weak-refs))

(defn- save-process-env
  []
  {:cwd (os/cwd)
   :environ (os/environ)})

(defn- restore-process-env
  [{:cwd cwd
    :environ environ}]
  (eachk k environ
     (os/setenv k (environ k)))
  (os/cd cwd))

(def pkg-loading-env (merge-into @{} root-env))
(put pkg-loading-env 'pkg    @{:value pkg})
(put pkg-loading-env 'fetch  @{:value fetch})
(put pkg-loading-env 'unpack @{:value unpack})
(put pkg-loading-env 'sh/$   @{:value sh/$})
(put pkg-loading-env 'sh/$$  @{:value sh/$$})
(put pkg-loading-env 'sh/$$_ @{:value sh/$$_})
(put pkg-loading-env 'sh/$?  @{:value sh/$?})
(def marshal-client-pkg-registry (invert (env-lookup pkg-loading-env)))

(defn load-pkgs
  [fpath]

  (defn clear-table 
    [t]
    (each k (keys t) # don't mutate while iterating.
      (put t k 0))
    t)
  
  (defn clear-array
    [a]
    (array/remove a 0 (length a))
    a)

  (def saved-process-env (save-process-env)) # XXX shouldn't be needed with proper sandboxed env.
  (def saved-root-env (merge-into @{} root-env))
  (def saved-mod-paths (array ;module/paths))
  (def saved-mod-cache (merge-into @{} module/cache))

  (defer (do
           (clear-table module/cache)
           (merge-into module/cache saved-mod-cache)

           (clear-array module/paths)
           (array/concat module/paths saved-mod-paths)

           (clear-table root-env)
           (merge-into root-env saved-root-env)
           
           (restore-process-env saved-process-env))
    
    (clear-table root-env)
    (merge-into root-env pkg-loading-env)

    # Clear module cache.
    (clear-table module/cache)
    
    # Remove all paths, to ensure hermetic package env.
    (defn- check-. [x] (if (string/has-prefix? "." x) x))
    (clear-array module/paths)
    (array/concat module/paths @[[":cur:/:all:.janet" :source check-.]])

    # XXX it would be nice to not exit on error, but raise an error.
    # this is easier for now though.
    (dofile fpath :exit true)))

(defn init-store
  [&opt path]
  (default path *store-path*)
  (os/mkdir path)
  (os/mkdir (string path "/lock"))
  (spit (string path "/lock/gc.lock") "")
  (spit (string path "/cfg.jdn") `
{
  # Build users used for sandboxed package builds.
  :build-users [
    "ac" # XXX TODO
  ]
}
  `)

  (os/mkdir (string path "/pkg"))
  (with [db (sqlite3/open (string path "/hermes.db"))]
    (sqlite3/eval db "begin transaction;")
    (when (empty? (sqlite3/eval db "select name from sqlite_master where type='table' and name='Meta'"))
      (sqlite3/eval db "create table Roots(LinkPath text primary key);")
      (sqlite3/eval db "create table Pkgs(Hash text primary key, Name text);")
      (sqlite3/eval db "create table Meta(Key text primary key, Value text);")
      (sqlite3/eval db "insert into Meta(Key, Value) Values('StoreVersion', 1);")
      (sqlite3/eval db "commit;")))
  nil)

(defn load-store-config
  []
  (jdn/decode (slurp (string *store-path* "/cfg.jdn"))))

(defn compute-build-dep-info
  [pkg]
  (def deps @{})
  (def order @[])
  (defn compute-build-dep-info2
    [pkg]
    (if (deps pkg)
      nil
      (let [direct-deps (_hermes/pkg-dependencies pkg)]
        (put deps pkg (keys direct-deps))
        (eachk dep direct-deps
          (compute-build-dep-info2 dep))
        (array/push order pkg))))
  (compute-build-dep-info2 pkg)
  {:deps deps
   :order order})

(defn- pkg-dir-name-from-parts [hash name]
  (if name
    (string hash "-" name)
    (string hash)))

(defn ref-scan
  [db pkg]
  # Because package names are not fixed length, the scanner can only scan for hashes. 
  # We must reconstruct the full package path by fetching from the database.
  (def hash-set (_hermes/hash-scan *store-path* pkg @{}))
  (def refs @[])
  (def hashes (keys hash-set))
  (sort hashes)
  (each h hashes
    (when-let [row (first (sqlite3/eval db "select Name from Pkgs where Hash = :hash;" {:hash h}))]
      (array/push refs (pkg-dir-name-from-parts h (row :Name)))))
  refs)

(var- aquire-build-user-counter 0)
(defn aquire-build-user
  [cfg]
  (def users (get cfg :build-users []))
  (when (empty? users)
    (error "build user list empty, unable to build."))

  (defn select-and-lock-build-user
    [users idx]
    (if (= idx (length users))
      (do
        # XXX exp backoff?
        (os/sleep 0.5)
        (select-and-lock-build-user users 0))
      (let [u (users idx)]
        (if-let [user-lock (flock/acquire (string *store-path* "/lock/user-" u ".lock") :noblock :exclusive)]
          @{:user u :lock user-lock :close (fn [self] (:close (self :lock)))}
          (select-and-lock-build-user users (inc idx))))))
  (def start-idx (mod (++ aquire-build-user-counter) (length users)))
  (if (cfg :lock-build-users)
    (select-and-lock-build-user users start-idx)
    @{:user (users start-idx) :close (fn [self] nil)}))

(defn- build-lock-cleanup
  []
  (def all-locks (os/dir (string *store-path* "/lock")))
  (def pkg-locks (filter |(not= $ "gc.lock") all-locks))
  (each l pkg-locks
    (os/rm (string *store-path* "/lock/" l))))

(defn- optimistic-build-lock-cleanup
  []
  (when-let [gc-lock (flock/acquire (string *store-path* "/lock/gc.lock") :noblock :exclusive)]
    (build-lock-cleanup)
    (:close gc-lock)))

(defn has-pkg-with-hash
  [db hash]
  (not (empty? (sqlite3/eval db "select 1 from Pkgs where Hash=:hash" {:hash hash}))))

(defn build
  [pkg &opt root]

  (def cfg (load-store-config))

  (def dep-info (compute-build-dep-info pkg))

  # Copy registry so we can update it as we build packages.
  (def registry (merge-into @{} builder-registry))
  
  (each p (dep-info :order)
    (put registry (p :builder) '*pkg-noop-build*))

  (each p (dep-info :order)
    # Hash the packages in order as children must be hashed first.
    (pkg-hash p))

  (with [flock (flock/acquire (string *store-path* "/lock/gc.lock") :block :shared)]
  (with [db (sqlite3/open (string *store-path* "/hermes.db"))]
    
    (defn has-pkg
      [pkg]
      (has-pkg-with-hash db (pkg :hash)))

    (defn build2
      [pkg]
      (unless (has-pkg pkg)
        (each dep (get-in dep-info [:deps pkg])
          (unless (has-pkg dep)
            (build2 dep)))

        (with [build-user (aquire-build-user cfg)]
        (with [flock (flock/acquire (string *store-path* "/lock/build-" (pkg :hash) ".lock") :block :exclusive)]
          # After aquiring the package lock, check again that it doesn't exist.
          # This is in case multiple builders were waiting.
          (when (not (has-pkg pkg))
            
            (when (os/stat (pkg :path))
              (sh/$ ["chmod" "-R" "u+w" (pkg :path)])
              (sh/$ ["rm" "-rf" (pkg :path)]))
            
            (sh/$ ["mkdir" (pkg :path)])

            (def tmpdir (sh/$$_ ["mktemp" "-d"]))
            (defer (do
                     (sh/$ ["chmod" "-R" "u+w" tmpdir])
                     (sh/$ ["rm" "-r" tmpdir]))
              
              (def tmp (string tmpdir "/tmp"))
              (def bin (string tmpdir "/bin"))
              (def usr-bin (string tmpdir "/usr/bin"))
              (def build (string tmpdir "/tmp/build"))
              (def jail-store-path (string tmpdir *store-path*))

              (sh/$ ["mkdir" "-p" build bin usr-bin jail-store-path])

              (defn do-build []
                (os/cd "/tmp/build")
                (with-dyns [:pkg-out (pkg :path)]
                  ((pkg :builder))))

              (def thunk-path (string tmpdir "/tmp/.pkg.thunk"))
              (put registry (pkg :builder) nil)
              (spit thunk-path (marshal do-build registry))
              (put registry (pkg :builder) '*pkg-noop-build*)

              (sh/$ [
                "nsjail"
                "-M" "o"
                "-q"
                "--chroot" "/"
                "--rlimit_as" "max"
                "--rlimit_cpu" "max"
                "--rlimit_fsize" "max"
                "--rlimit_nofile" "max"
                "--rlimit_nproc" "max"
                "--rlimit_stack" "max"
                ;(if (pkg :content) ["--disable_clone_newnet"] [])
                "--bindmount" (string bin ":/bin")
                "--bindmount" (string tmp ":/tmp")
                "--bindmount_ro" (string *store-path* ":" *store-path*)
                "--bindmount" (string (pkg :path) ":" (pkg :path))
                "--user" (string (build-user :user))
                # "--group" (string (build-user :group)) XXX TODO FIXME
                "--" (sh/$$_ ["which" "hermes-builder"]) "-t" "/tmp/.pkg.thunk"])) # XXX don't shell out.

            (def scanned-refs (ref-scan db pkg))
            
            # Set package permissions.
            (sh/$ ["chmod" "-R" "a-w,a+r,a+X" (pkg :path)])

            (when-let [content (pkg :content)]
              (match (check-pkg-content (pkg :path) content)
                [:fail msg]
                  (error msg)))

            # XXX It seems inefficient to shell out to chmod so many times.
            (sh/$ ["chmod" "u+w" (pkg :path)])

            (defn refset-to-dirnames
              [pkg set-key]
              (when-let [rs (pkg set-key)]
                (map |(pkg-dir-name-from-parts ($ :hash) ($ :name)) (pkg set-key))))

            (spit (string (pkg :path) "/.hpkg.jdn") (string/format "%j" {
              :name (pkg :name)
              :hash (pkg :hash)
              :force-refs (refset-to-dirnames pkg :force-refs)
              :weak-refs  (refset-to-dirnames pkg :weak-refs)
              :extra-refs (refset-to-dirnames pkg :extra-refs)
              :scanned-refs scanned-refs
              :content (pkg :content)
            }))

            (sh/$ ["chmod" "u-w" (pkg :path)])

            (sqlite3/eval db "insert into Pkgs(Hash, Name) Values(:hash, :name);"
              {:hash (pkg :hash) :name (pkg :name)}))))

          nil))

    (build2 pkg)

    (when root
      (sqlite3/eval db "insert or ignore into Roots(LinkPath) Values(:root);" {:root root})
      (def tmplink (string root ".hermes-root"))
      (when (os/stat tmplink)
        (os/rm tmplink))
      (os/link (pkg :path) tmplink true)
      (os/rename tmplink root))))
    
    (optimistic-build-lock-cleanup)
    
    nil)

(defn path-to-pkg-parts
  [path]
  (def tail-peg (comptime (peg/compile ~{
    :hash (capture (repeat 40 (choice (range "09") (range "af"))))
    :name (choice (sequence "-" (capture (some (sequence (not "/") 1))))
                  (constant nil))
    :main (sequence "/pkg/" :hash :name)
  })))
  (when (string/has-prefix? *store-path* path)
    (def tail (string/slice path (length *store-path*)))
    (peg/match tail-peg tail)))

(defn gc
  []
  (with [flock (flock/acquire (string *store-path* "/lock/gc.lock") :block :exclusive)]
  (with [db (sqlite3/open (string *store-path* "/hermes.db"))]

    (def work-q @[])
    (def visited @{})

    (defn process-roots
      []
      (def dead-roots @[])
      (def roots (map |($ :LinkPath) (sqlite3/eval db "select * from Roots;")))
      (each root roots
        (if-let [rstat (os/lstat root)
                 is-link (= :link (rstat :mode))
                 [hash name] (path-to-pkg-parts (os/readlink root))
                 have-pkg (has-pkg-with-hash db hash)]
          (array/push work-q (string *store-path* "/pkg/" (pkg-dir-name-from-parts hash name)))
          (array/push dead-roots root)))
      (sqlite3/eval db "begin transaction;")
      (each root dead-roots
        (sqlite3/eval db "delete from Roots where LinkPath = :root;" {:root root}))
      (sqlite3/eval db "commit;"))

    (defn gc-walk []
      (unless (empty? work-q)
        (def pkg-dir (array/pop work-q))
        (if (visited pkg-dir)
          (gc-walk)
          (do
            (put visited pkg-dir true)
            (def pkg-info (jdn/decode (slurp (string pkg-dir "/.hpkg.jdn"))))
            (def ref-to-full-path |(string *store-path* "/pkg/" $))
            (array/concat work-q
              (map ref-to-full-path
                (if (pkg-info :force-refs)
                  (pkg-info :force-refs)
                  (let [refs (array/concat @[]
                               (get pkg-info :scanned-refs [])
                               (get pkg-info :extra-refs []))]
                    (if-let [weak-refs (pkg-info :weak-refs)]
                      (filter |(get weak-refs $) refs)
                      refs)))))
            (gc-walk)))))
    
    (process-roots)
    (gc-walk)

    (each dirname (os/dir (string *store-path* "/pkg/"))
      (def pkg-dir (string *store-path* "/pkg/" dirname))
      (unless (visited pkg-dir)
        (when-let [[hash name] (path-to-pkg-parts pkg-dir)]
          (sqlite3/eval db "delete from Pkgs where Hash = :hash;" {:hash hash}))
        (eprintf "deleting %s" pkg-dir)
        (sh/$ ["chmod" "-R" "u+w" pkg-dir])
        (sh/$ ["rm" "-rf" pkg-dir])))

    (build-lock-cleanup)

    nil)))

