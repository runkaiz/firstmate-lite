if [[ "$0" == */fm-procevent-ci.test.sh ]]; then
  capture_ci_evidence() {
    case "$BASH_COMMAND" in
      "check 'zero checks surface at ten"*|"check 'checks disappearing"*|"check 'repair allows"*|"check 'unreadable forge does"*|"check 'runner-hosted wait surfaces"*)
        {
          printf '\nObservation: %s\n' "$BASH_COMMAND"
          printf 'controlled daemon scenario=%s initial_checks=%s\n' "${CI_SCENARIO:-}" "${CI_CHECKS:-unreadable}"
          printf 'accelerated hold clock: '; cat "$LAB/clock" 2>/dev/null || true
          printf 'real product durable wake queue:\n'
          if [[ -s "${queue:-}" ]]; then cat "$queue"; else printf '(empty)\n'; fi
          printf 'real product poll output:\n%s\n' "${out:-}"
        } >> /home/runkai/.no-mistakes/evidence/01M6HTF41B08PS6PG97VZ5PSAY/ci-controlled-transcript.txt
        ;;
    esac
  }
  trap capture_ci_evidence DEBUG
fi
