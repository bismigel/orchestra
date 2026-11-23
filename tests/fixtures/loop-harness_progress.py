"""Progress reader for the fake test harness: it writes pi-style events, so pi's reader applies."""
import os, runpy, sys
sys.argv[0] = "pi_progress.py"
runpy.run_path(os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..", "lib", "harness", "pi_progress.py"),
               run_name="__main__")
