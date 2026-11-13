let
  revision = "d361547b36663e2365398e85ed228634d97459fd";
  engine = builtins.fetchGit {
    url = "https://github.com/40ants/ai-evals.git";
    rev = revision;
  };
in import (engine + "/shell.nix") {
  projectRoot = toString ./.;
  engineRevision = revision;
}
