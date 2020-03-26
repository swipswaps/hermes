(declare-project
  :name "hermes"
  :author "Andrew Chambers"
  :license "MIT"
  :url "https://github.com/andrewchambers/hermes"
  :repo "git+https://github.com/andrewchambers/hermes.git"
  :dependencies [
    "https://github.com/janet-lang/sqlite3.git"
    "https://github.com/janet-lang/argparse.git"
    "https://github.com/andrewchambers/janet-jdn.git"
    "https://github.com/andrewchambers/janet-flock.git"
    "https://github.com/andrewchambers/janet-process.git"
    "https://github.com/andrewchambers/janet-sh.git"
  ])

(declare-source
  :name "hermes"
  :source ["hermes.janet"])

(declare-native
  :name "_hermes"
  :cflags ["-g"]
  :headers ["hermes.h" "sha1.h"]
  :source ["hermes.c" "util.c" "sha1.c" "pkghash.c" "deps.c" "hashscan.c"])

#(declare-executable
# :name "hermes"
# :entry "main.janet")