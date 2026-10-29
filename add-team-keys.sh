#!/bin/bash
# Create one login per row in the DevOps public-key CSV.
# Passwords stay locked. SSH works with the public key. sudo asks for a password.
# Rejects private keys. Does not copy accounts that are absent from the CSV.
set -euo pipefail

if [[ "$(id -u)" -ne 0 ]]; then
  echo "Run as root." >&2
  exit 1
fi

CSV="${1:?usage: add-team-keys.sh /path/to/keys.csv}"
if [[ ! -f "$CSV" ]]; then
  echo "CSV not found: $CSV" >&2
  exit 1
fi

username_for() {
  case "$1" in
    Manish) echo manish ;;
    Pradip) echo pradip ;;
    Siddhart) echo siddharth ;;
    Rushikesh) echo rushikesh ;;
    Tushar) echo tushar ;;
    Udit) echo udit ;;
    Saurabh) echo saurabh ;;
    "Rohit Raut") echo rohit ;;
    "Harsh Shah") echo harsh ;;
    Ashutosh) echo ashutosh ;;
    Dhaval) echo dhaval ;;
    Anil) echo anil ;;
    *) echo "" ;;
  esac
}

while IFS= read -r line || [[ -n "$line" ]]; do
  line="${line%$'\r'}"
  [[ -z "$line" ]] && continue
  name="${line%%,*}"
  key="${line#*,}"
  user="$(username_for "$name")"
  if [[ -z "$user" ]]; then
    echo "Unknown name in CSV: $name" >&2
    exit 1
  fi
  if [[ "$key" == *"PRIVATE KEY"* ]]; then
    echo "Refusing private key for $name" >&2
    exit 1
  fi
  tmp="$(mktemp)"
  printf '%s\n' "$key" > "$tmp"
  if ! ssh-keygen -lf "$tmp" >/dev/null; then
    echo "Not a public key for $name" >&2
    rm -f "$tmp"
    exit 1
  fi
  fingerprint="$(ssh-keygen -lf "$tmp")"

  if ! id "$user" >/dev/null 2>&1; then
    useradd -m -s /bin/bash "$user"
  fi
  passwd -l "$user" >/dev/null
  group="$(id -gn "$user")"
  install -d -m 700 -o "$user" -g "$group" "/home/$user/.ssh"
  install -m 600 -o "$user" -g "$group" "$tmp" "/home/$user/.ssh/authorized_keys"
  rm -f "$tmp"
  restorecon -R "/home/$user/.ssh" >/dev/null 2>&1 || true
  printf '%s ALL=(ALL) PASSWD:ALL\n' "$user" > "/etc/sudoers.d/$user"
  chmod 440 "/etc/sudoers.d/$user"
  visudo -cf "/etc/sudoers.d/$user" >/dev/null
  echo "installed $user  $fingerprint"
done < <(tail -n +2 "$CSV")

echo "Team keys installed. sudo for these accounts requires a password, and no password was set."
