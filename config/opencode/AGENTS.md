# Global rules (Qt / C++ photogrammetry, Linux build container)

## Environment
- You run in a Linux container without internet. Do not try to download anything.
- If a request fails because a site is blocked (for example a 403 from the proxy), do not look for a workaround. Tell the user the exact domain and ask them to allow it.
- Source is in /workspace. Build output goes ONLY to /cache/build/$PROJECT_NAME.
- Build and test: see the `qt-cmake-build` skill if available.
- Windows-only code (MSVC, WinAPI) cannot build here: report it, do not "fix" it.

## Code
- C++17 or newer as the project dictates. Follow the project's .clang-format; run clang-format on files you edit.
- Prefer RAII and value types. No raw owning pointers. Use Qt parent/child ownership for QObjects.
- Do not reformat unrelated code. Do not change line endings of existing files.
- Numerics (Ceres, Eigen, bundle adjustment): do not change tolerances, solver options or parameterisations unless asked; explain reasoning for any numeric change.

## Workflow
- Make small, reviewable changes. Run the relevant tests before saying you are done.
- Show only the first error and its context when a build fails; never paste full logs.
- Do not commit unless asked. If you do commit: the message states what the commit does, in the imperative, without a "This commit will" prefix, and ends with `[task-number]` when a task number was given.
- Do not edit files under .git, .vscode, or the skills folder (they are read-only anyway).