# Minimal Boost "config package" shim for using a plain Boost *source tree*
# (headers-only usage) with CMake >= 3.31, which removed the FindBoost module.
#
# Usage:
#   cmake ... -DBoost_DIR=<dir of this file> -DBITTE_BOOST_INCLUDE=<boost src root>
#
# libtorrent only needs Boost::headers (Boost >= 1.69 has header-only
# Boost.System), so this shim is sufficient.

if(NOT DEFINED BITTE_BOOST_INCLUDE)
    message(FATAL_ERROR "BITTE_BOOST_INCLUDE must point at the Boost source tree root")
endif()

if(NOT EXISTS "${BITTE_BOOST_INCLUDE}/boost/version.hpp")
    message(FATAL_ERROR "No boost/version.hpp under BITTE_BOOST_INCLUDE=${BITTE_BOOST_INCLUDE}")
endif()

# read the real version from version.hpp
file(STRINGS "${BITTE_BOOST_INCLUDE}/boost/version.hpp" _boost_ver_line
     REGEX "#define BOOST_LIB_VERSION ")
string(REGEX REPLACE ".*\"([0-9_]+)\".*" "\\1" _boost_lib_ver "${_boost_ver_line}")
string(REPLACE "_" "." Boost_VERSION "${_boost_lib_ver}")
string(REGEX MATCH "^[0-9]+" Boost_MAJOR_VERSION "${Boost_VERSION}")
string(REGEX REPLACE "^([0-9]+)\\.([0-9]+).*" "\\2" Boost_MINOR_VERSION "${Boost_VERSION}")

if(NOT TARGET Boost::headers)
    add_library(Boost::headers INTERFACE IMPORTED GLOBAL)
    set_target_properties(Boost::headers PROPERTIES
        INTERFACE_INCLUDE_DIRECTORIES "${BITTE_BOOST_INCLUDE}")
endif()

set(Boost_FOUND TRUE)
set(Boost_INCLUDE_DIRS "${BITTE_BOOST_INCLUDE}")
set(Boost_VERSION_STRING "${Boost_VERSION}")

if(NOT Boost_FIND_QUIETLY)
    message(STATUS "Boost shim: using headers-only Boost ${Boost_VERSION} at ${BITTE_BOOST_INCLUDE}")
endif()
