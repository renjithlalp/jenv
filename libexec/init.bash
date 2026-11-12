# jenv shell integration (bash). Loaded by:  eval "$(command jenv init)"
# 'jenv use', 'jenv deactivate' and 'jenv init' must change THIS shell, so they are eval'ed here.
jenv() {
  case "${1:-}" in
    use|deactivate) eval "$(command jenv __env "$@")" ;;
    init)
      if [ $# -eq 1 ]; then eval "$(command jenv __env init)"; else command jenv "$@"; fi ;;
    *) command jenv "$@" ;;
  esac
}
