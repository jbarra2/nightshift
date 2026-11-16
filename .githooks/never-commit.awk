# never-commit.awk: reads one path per line and prints each path that must
# never be committed. pre-commit runs it on the staged paths, and pre-push on
# the paths in every outgoing commit.
#
# It mirrors the "never commit" groups in .gitignore, checked on every part of
# the path and in any letter case:
#   - a private/ or secrets/ folder;
#   - .env, and any *.env;
#   - .env.<anything>, except .env.example;
#   - key and certificate files: *.pem, *.key, id_rsa*, id_ecdsa*, id_ed25519*;
#   - *.local.* (for example settings.local.json or CLAUDE.local.md).
{
    bad = 0
    n = split($0, part, "/")
    for (i = 1; i <= n; i++) {
        c = tolower(part[i])
        if (i < n && (c == "private" || c == "secrets")) bad = 1
        if (c ~ /\.env$/) bad = 1
        if (c ~ /^\.env\./ && c != ".env.example") bad = 1
        if (c ~ /\.(pem|key)$/) bad = 1
        if (c ~ /^id_(rsa|ecdsa|ed25519)/) bad = 1
        if (c ~ /\.local\./) bad = 1
    }
    if (bad) print
}
