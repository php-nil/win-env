# CMake glue for the self-contained opencv_shim.dll (gnu route).
# Driven by build.ps1 (-Stage shim / -Stage all), which passes
# -DOpenCV_DIR=<MinGW install prefix dir that holds OpenCVConfig.cmake>.
# Source: opencv_shim.cpp (single export shim_match_template).
cmake_minimum_required(VERSION 3.15)
project(opencv_shim LANGUAGES CXX)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)

find_package(OpenCV REQUIRED COMPONENTS core imgproc)

add_library(opencv_shim SHARED opencv_shim.cpp)
# MinGW would otherwise emit libopencv_shim.dll; the workflow stages a plain
# opencv_shim.dll (same name the MSVC route produces).
set_target_properties(opencv_shim PROPERTIES PREFIX "")
target_include_directories(opencv_shim PRIVATE ${OpenCV_INCLUDE_DIRS})
target_link_libraries(opencv_shim PRIVATE ${OpenCV_LIBS})

# g++ links the *shared* libgcc / libstdc++ by default (that is why GCC offers
# -static-libstdc++: "if libstdc++ is available as a shared library, and -static
# is not used, then this links against the shared version"). Leaving the defaults
# would drag libstdc++-6.dll / libgcc_s_seh-1.dll into the delivery and break the
# single-file, self-contained contract that the workflow's dependency gate
# enforces.
#
# -static-libgcc -static-libstdc++ alone is NOT enough on the WinLibs
# x86_64-posix-seh toolchain: it uses the POSIX thread model, so even the static
# libstdc++ keeps a dynamic import of libwinpthread-1.dll (CI fact: the gnu gate
# saw libwinpthread-1.dll in the import table while both flags were already set).
# Use -static instead -- a superset that static-links libgcc, libstdc++ AND
# libwinpthread. The OS CRT has no static form on MinGW (only import libs), so
# msvcrt.dll / ucrtbase.dll stay dynamic imports, as does KERNEL32.dll -- which is
# exactly what the gate allows.
if(MINGW)
  # Per-function/data sections so the linker can drop unreferenced ones below;
  # the OpenCV static libs get the same flags from build.ps1
  # (CMAKE_*_FLAGS_RELEASE), otherwise whole-object granularity makes
  # --gc-sections nearly useless for library code.
  target_compile_options(opencv_shim PRIVATE -ffunction-sections -fdata-sections)
  # -static: see the libwinpthread rationale above.
  # -s: strip the COFF symbol table from the final DLL. GNU ld keeps every
  #     symbol of the statically linked OpenCV libs (tens of thousands of
  #     names, MBs of .strtab) in the DLL; MSVC link.exe never writes a symbol
  #     table into its output, which is why a cl-built shim of the same code
  #     is a fraction of the size.
  # -Wl,--gc-sections: drop unreferenced sections (the /OPT:REF equivalent
  #     MSVC applies by default in Release). The exported shim_match_template
  #     is a root, so the single-export contract is untouched; import/export
  #     tables are PE data directories and survive stripping, so both gates
  #     (objdump -p / Get-PeExportName) keep working.
  target_link_options(opencv_shim PRIVATE -static -s -Wl,--gc-sections)
endif()
