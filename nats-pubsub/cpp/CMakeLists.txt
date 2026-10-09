cmake_minimum_required(VERSION 3.14)
project(nats_pubsub_cpp CXX C)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
if(NOT CMAKE_BUILD_TYPE)
  set(CMAKE_BUILD_TYPE Release)
endif()

# The official NATS C client (https://github.com/nats-io/nats.c) is downloaded
# and built automatically. TLS is switched off so there is no OpenSSL
# dependency; set NATS_BUILD_WITH_TLS to ON if you need tls:// URLs.
include(FetchContent)
set(NATS_BUILD_WITH_TLS   OFF CACHE BOOL "" FORCE)
set(NATS_BUILD_EXAMPLES   OFF CACHE BOOL "" FORCE)
set(NATS_BUILD_STREAMING  OFF CACHE BOOL "" FORCE)
set(NATS_BUILD_LIB_SHARED OFF CACHE BOOL "" FORCE)
set(NATS_BUILD_LIB_STATIC ON  CACHE BOOL "" FORCE)
set(BUILD_TESTING         OFF CACHE BOOL "" FORCE)
FetchContent_Declare(
  natsc
  GIT_REPOSITORY https://github.com/nats-io/nats.c.git
  GIT_TAG        v3.14.0
  GIT_SHALLOW    TRUE
)
FetchContent_MakeAvailable(natsc)

find_package(Threads REQUIRED)

foreach(app publisher subscriber loadtest)
  add_executable(${app} ${app}.cpp)
  target_link_libraries(${app} PRIVATE nats_static Threads::Threads)
endforeach()
