---
name: qt-cmake-build
description: Configure, build and test this Qt/CMake project inside the Linux container. Use when asked to build, run tests, fix compile errors or check that a change compiles.
---

# Build and test (Linux container)

1. Build directory is always `/cache/build/$PROJECT_NAME`. Never create build output in `/workspace`.
2. Configure once:
   cmake -S /workspace -B /cache/build/$PROJECT_NAME -G Ninja -DCMAKE_BUILD_TYPE=RelWithDebInfo
3. Build: `cmake --build /cache/build/$PROJECT_NAME -j`
4. Test: `ctest --test-dir /cache/build/$PROJECT_NAME --output-on-failure -j`
   Qt GUI tests run headless (`QT_QPA_PLATFORM=offscreen` is preset).
5. When output is long, show only the first error and its context; do not paste whole logs.
6. Windows-only code (MSVC, WinAPI) does not build here. Report that instead of changing it.