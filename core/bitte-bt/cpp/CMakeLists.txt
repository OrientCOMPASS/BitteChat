cmake_minimum_required(VERSION 3.20)
project(bitte_bt_cpp CXX)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_POSITION_INDEPENDENT_CODE ON)
set(CMAKE_CXX_VISIBILITY_PRESET hidden)
set(CMAKE_VISIBILITY_INLINES_HIDDEN ON)

if(NOT CMAKE_BUILD_TYPE)
  set(CMAKE_BUILD_TYPE Release)
endif()

add_library(bitte_bt_cpp STATIC bitte_torrent.cpp)

target_compile_definitions(bitte_bt_cpp PRIVATE
  TORRENT_NO_DEPRECATE
  BOOST_ALL_NO_LIB
  BOOST_ASIO_ENABLE_CANCELIO
  BOOST_SYSTEM_USE_UTF8
)

target_compile_options(bitte_bt_cpp PRIVATE
  -fexceptions
  -fvisibility=hidden
  -Wno-unused-parameter
)

# exported C ABI symbols must stay visible
set_source_files_properties(bitte_torrent.cpp PROPERTIES
  COMPILE_FLAGS "-fvisibility=hidden")
target_compile_definitions(bitte_bt_cpp PRIVATE
  BC_EXPORTS=1
)

# libtorrent (prebuilt static, with its Boost/OpenSSL interface deps)
find_package(LibtorrentRasterbar REQUIRED CONFIG)
target_link_libraries(bitte_bt_cpp PUBLIC LibtorrentRasterbar::torrent-rasterbar)

# install into the deps prefix so rustc can find it via BITTE_BT_PREFIX
install(TARGETS bitte_bt_cpp ARCHIVE DESTINATION lib)
install(FILES bitte_torrent.h DESTINATION include)
