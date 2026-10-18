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
# enforces. Link both statically; the OS CRT (msvcrt / ucrtbase) stays dynamic.
if(MINGW)
  target_link_options(opencv_shim PRIVATE -static-libgcc -static-libstdc++)
endif()
