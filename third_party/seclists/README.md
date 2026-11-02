# SecLists

The most common passwords: `10k-most-common.txt` from SecLists by Daniel Miessler, Jason Haddix and g0tmi1k, at
`Passwords/Common-Credentials/10k-most-common.txt` in https://github.com/danielmiessler/SecLists, under the MIT license
in `LICENSE`.

`src/account_records/_generator/generate.py` writes `src/account_records/common_passwords.hsc` from it: the 2,087 of 8
characters or more, lowercased and sorted, which the account service refuses as passwords (`knowledge/decisions/0141`).
