# Contributing to 00Widget

Thanks for helping improve 00Widget. Keep pull requests focused, explain the
user-visible effect, and include tests for backend behavior changes.

## Local setup

The backend requires Node.js 22 or newer:

```sh
cd server
npm ci
npm run typecheck
npm test
```

For iOS work, copy `ios/project.yml.sample` to the gitignored
`ios/project.yml`, set your own Apple identifiers, run `xcodegen`, and build
with Xcode 26 or newer. See `AGENTS.md` and `ios/README.md` for the complete
project-specific checks.

## Protect credentials

Pull-request workflows never receive deployment credentials, Cloudflare
secrets, APNs private keys, Apple signing material, or maintainer environment
files. Tests must use fake services and clearly non-secret fixture values.

- Never commit `.dev.vars`, `.env` variants, `wrangler.toml`,
  `ios/project.yml`, APNs `.p8` files, signing certificates, provisioning
  profiles, or exported archives.
- Update committed `.sample` or `.example` files when shared configuration
  changes, and keep their public placeholder values intact.
- Do not add repository or environment secrets merely to make a pull-request
  workflow pass.
- Report suspected vulnerabilities privately as described in `SECURITY.md`.

## Pull requests

Before opening a pull request:

1. Run `npm ci`, `npm run typecheck`, and `npm test` in `server/`.
2. Run `./scripts/check-public-placeholders.sh` from the repository root.
3. Keep the Swift models in `ios/Sources/Shared/Models/` synchronized with
   the Zod schemas in `server/src/types.ts`.
4. Add positive and negative tests for new backend endpoints.
5. Confirm that the diff contains no credentials or developer-specific Apple
   identifiers.

CI repeats the backend, placeholder, dependency, static-analysis, and secret
checks. Deployment and end-to-end APNs testing remain maintainer-controlled
because pull-request workflows intentionally have no access to those secrets.
