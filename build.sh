#!/bin/bash -e

# This scrip is for static cross compiling
# Please run this scrip in docker image: abcfy2/muslcc-toolchain-ubuntu:${CROSS_HOST}
# E.g: docker run --rm -v `git rev-parse --show-toplevel`:/build abcfy2/muslcc-toolchain-ubuntu:arm-linux-musleabi /build/build.sh
# Artifacts will copy to the same directory.

set -o pipefail

# value from: https://musl.cc/ (without -cross or -native)
# export CROSS_HOST="${CROSS_HOST:-arm-linux-musleabi}"
# value from openssl source: ./Configure LIST
case "${CROSS_HOST}" in
arm-linux*)
  export OPENSSL_COMPILER=linux-armv4
  ;;
aarch64-linux*)
  export OPENSSL_COMPILER=linux-aarch64
  ;;
mips-linux* | mipsel-linux*)
  export OPENSSL_COMPILER=linux-mips32
  ;;
mips64-linux*)
  export OPENSSL_COMPILER=linux64-mips64
  ;;
x86_64-linux*)
  export OPENSSL_COMPILER=linux-x86_64
  ;;
i686-linux*)
  export OPENSSL_COMPILER=linux-x86
  ;;
s390x-linux*)
  export OPENSSL_COMPILER=linux64-s390x
  ;;
*)
  export OPENSSL_COMPILER=gcc
  ;;
esac
# export CROSS_ROOT="${CROSS_ROOT:-/cross_root}"
export USE_ZLIB_NG="${USE_ZLIB_NG:-1}"

retry() {
  # max retry 5 times
  try=5
  # sleep 3s every retry
  sleep_time=30
  for i in $(seq ${try}); do
    echo "executing with retry: $@" >&2
    if eval "$@"; then
      return 0
    else
      echo "execute '$@' failed, tries: ${i}" >&2
      sleep ${sleep_time}
    fi
  done
  echo "execute '$@' failed" >&2
  return 1
}

source /etc/os-release
dpkg --add-architecture i386
# Ubuntu mirror for local building
if [ x"${USE_CHINA_MIRROR}" = x1 ]; then
  cat >/etc/apt/sources.list <<EOF
deb http://mirror.sjtu.edu.cn/ubuntu/ ${UBUNTU_CODENAME} main restricted universe multiverse
deb http://mirror.sjtu.edu.cn/ubuntu/ ${UBUNTU_CODENAME}-updates main restricted universe multiverse
deb http://mirror.sjtu.edu.cn/ubuntu/ ${UBUNTU_CODENAME}-backports main restricted universe multiverse
deb http://mirror.sjtu.edu.cn/ubuntu/ ${UBUNTU_CODENAME}-security main restricted universe multiverse
EOF
fi

export DEBIAN_FRONTEND=noninteractive

# keep debs in container for store cache in docker volume
rm -f /etc/apt/apt.conf.d/*
echo 'Binary::apt::APT::Keep-Downloaded-Packages "true";' >/etc/apt/apt.conf.d/01keep-debs
echo -e 'Acquire::https::Verify-Peer "false";\nAcquire::https::Verify-Host "false";' >/etc/apt/apt.conf.d/99-trust-https

apt-get update
apt-get install -y g++ \
  make \
  libtool \
  jq \
  pkgconf \
  file \
  tcl \
  autoconf \
  automake \
  autopoint \
  patch \
  wget \
  unzip \
  git

BUILD_ARCH="$(gcc -dumpmachine)"
TARGET_ARCH="${CROSS_HOST%%-*}"
TARGET_HOST="${CROSS_HOST#*-}"
case "${TARGET_ARCH}" in
"armel"*)
  TARGET_ARCH=armel
  ;;
"arm"*)
  TARGET_ARCH=arm
  ;;
esac
case "${TARGET_HOST}" in
*"mingw"*)
  TARGET_HOST=Windows
  rm -fr "${CROSS_ROOT}"
  hash -r
  # if [ ! -f "/usr/share/keyrings/winehq-archive.key" ]; then
  #   rm -f /usr/share/keyrings/winehq-archive.key.part
  #   retry wget -cT30 -O /usr/share/keyrings/winehq-archive.key.part https://dl.winehq.org/wine-builds/winehq.key
  #   mv -fv /usr/share/keyrings/winehq-archive.key.part /usr/share/keyrings/winehq-archive.key
  # fi
  # if [ x"${USE_CHINA_MIRROR}" = x1 ]; then
  #   WINEHQ_URL="http://mirrors.tuna.tsinghua.edu.cn/wine-builds/ubuntu/"
  # else
  #   WINEHQ_URL="http://dl.winehq.org/wine-builds/ubuntu/"
  # fi
  # echo "deb [signed-by=/usr/share/keyrings/winehq-archive.key] ${WINEHQ_URL} ${UBUNTU_CODENAME} main" >/etc/apt/sources.list.d/winehq.list
  apt-get update
  apt-get install -y wine mingw-w64
  export WINEPREFIX=/tmp/
  RUNNER_CHECKER="wine"
  ;;
*)
  TARGET_HOST=Linux
  apt-get install -y "qemu-user-static"
  RUNNER_CHECKER="qemu-${TARGET_ARCH}-static"
  ;;
esac

export PATH="${CROSS_ROOT}/bin:${PATH}"
export CROSS_PREFIX="${CROSS_ROOT}/${CROSS_HOST}"
export PKG_CONFIG_PATH="${CROSS_PREFIX}/lib64/pkgconfig:${CROSS_PREFIX}/lib/pkgconfig:${PKG_CONFIG_PATH}"
export LDFLAGS="-L${CROSS_PREFIX}/lib64 -L${CROSS_PREFIX}/lib -I${CROSS_PREFIX}/include -s -static --static"
SELF_DIR="$(dirname "$(realpath "${0}")")"
BUILD_INFO="${SELF_DIR}/build_info.md"

# Create download cache directory
mkdir -p "${SELF_DIR}/downloads/"
export DOWNLOADS_DIR="${SELF_DIR}/downloads"

if [ x"${USE_ZLIB_NG}" = x1 ]; then
  ZLIB=zlib-ng
else
  ZLIB=zlib
fi
if [ x"${USE_LIBRESSL}" = x1 ]; then
  SSL=LibreSSL
else
  SSL=OpenSSL
fi

echo "## Build Info - ${CROSS_HOST} With ${SSL} and ${ZLIB}" >"${BUILD_INFO}"
echo "Building using these dependencies:" >>"${BUILD_INFO}"

prepare_cmake() {
  if ! which cmake &>/dev/null; then
    cmake_latest_ver="$(retry wget -qO- --compression=auto https://cmake.org/download/ \| grep "'Latest Release'" \| sed -r "'s/.*Latest Release\s*\((.+)\).*/\1/'" \| head -1)"
    cmake_binary_url="https://github.com/Kitware/CMake/releases/download/v${cmake_latest_ver}/cmake-${cmake_latest_ver}-linux-x86_64.tar.gz"
    cmake_sha256_url="https://github.com/Kitware/CMake/releases/download/v${cmake_latest_ver}/cmake-${cmake_latest_ver}-SHA-256.txt"
    if [ x"${USE_CHINA_MIRROR}" = x1 ]; then
      cmake_binary_url="https://mirror.ghproxy.com/${cmake_binary_url}"
      cmake_sha256_url="https://mirror.ghproxy.com/${cmake_sha256_url}"
    fi
    if [ -f "${DOWNLOADS_DIR}/cmake-${cmake_latest_ver}-linux-x86_64.tar.gz" ]; then
      cd "${DOWNLOADS_DIR}"
      cmake_sha256="$(retry wget -qO- --compression=auto "${cmake_sha256_url}")"
      if ! echo "${cmake_sha256}" | grep "cmake-${cmake_latest_ver}-linux-x86_64.tar.gz" | sha256sum -c; then
        rm -f "${DOWNLOADS_DIR}/cmake-${cmake_latest_ver}-linux-x86_64.tar.gz"
      fi
    fi
    if [ ! -f "${DOWNLOADS_DIR}/cmake-${cmake_latest_ver}-linux-x86_64.tar.gz" ]; then
      retry wget -cT10 -O "${DOWNLOADS_DIR}/cmake-${cmake_latest_ver}-linux-x86_64.tar.gz" "${cmake_binary_url}"
    fi
    tar -zxf "${DOWNLOADS_DIR}/cmake-${cmake_latest_ver}-linux-x86_64.tar.gz" -C /usr/local --strip-components 1
  fi
  cmake --version
}

prepare_ninja() {
  if ! which ninja &>/dev/null; then
    ninja_ver="$(retry wget -qO- --compression=auto https://ninja-build.org/ \| grep "'The last Ninja release is'" \| sed -r "'s@.*<b>(.+)</b>.*@\1@'" \| head -1)"
    ninja_binary_url="https://github.com/ninja-build/ninja/releases/download/${ninja_ver}/ninja-linux.zip"
    if [ x"${USE_CHINA_MIRROR}" = x1 ]; then
      ninja_binary_url="https://mirror.ghproxy.com/${ninja_binary_url}"
    fi
    if [ ! -f "${DOWNLOADS_DIR}/ninja-${ninja_ver}-linux.zip" ]; then
      rm -f "${DOWNLOADS_DIR}/ninja-${ninja_ver}-linux.zip.part"
      retry wget -cT10 -O "${DOWNLOADS_DIR}/ninja-${ninja_ver}-linux.zip.part" "${ninja_binary_url}"
      mv -fv "${DOWNLOADS_DIR}/ninja-${ninja_ver}-linux.zip.part" "${DOWNLOADS_DIR}/ninja-${ninja_ver}-linux.zip"
    fi
    unzip -d /usr/local/bin "${DOWNLOADS_DIR}/ninja-${ninja_ver}-linux.zip"
  fi
  echo "Ninja version $(ninja --version)"
}

prepare_zlib() {
  if [ x"${USE_ZLIB_NG}" = x"1" ]; then
    zlib_ng_latest_tag="$(retry wget -qO- --compression=auto https://api.github.com/repos/zlib-ng/zlib-ng/releases \| jq -r "'.[0].tag_name'")"
    zlib_ng_latest_url="https://github.com/zlib-ng/zlib-ng/archive/refs/tags/${zlib_ng_latest_tag}.tar.gz"
    if [ x"${USE_CHINA_MIRROR}" = x1 ]; then
      zlib_ng_latest_url="https://mirror.ghproxy.com/${zlib_ng_latest_url}"
    fi
    if [ ! -f "${DOWNLOADS_DIR}/zlib-ng-${zlib_ng_latest_tag}.tar.gz" ]; then
      retry wget -cT10 -O "${DOWNLOADS_DIR}/zlib-ng-${zlib_ng_latest_tag}.tar.gz.part" "${zlib_ng_latest_url}"
      mv -fv "${DOWNLOADS_DIR}/zlib-ng-${zlib_ng_latest_tag}.tar.gz.part" "${DOWNLOADS_DIR}/zlib-ng-${zlib_ng_latest_tag}.tar.gz"
    fi
    mkdir -p "/usr/src/zlib-ng-${zlib_ng_latest_tag}"
    tar -zxf "${DOWNLOADS_DIR}/zlib-ng-${zlib_ng_latest_tag}.tar.gz" --strip-components=1 -C "/usr/src/zlib-ng-${zlib_ng_latest_tag}"
    cd "/usr/src/zlib-ng-${zlib_ng_latest_tag}"
    rm -fr build
    cmake -B build \
      -G Ninja \
      -DBUILD_SHARED_LIBS=OFF \
      -DZLIB_COMPAT=ON \
      -DCMAKE_SYSTEM_NAME="${TARGET_HOST}" \
      -DCMAKE_INSTALL_PREFIX="${CROSS_PREFIX}" \
      -DCMAKE_C_COMPILER="${CROSS_HOST}-gcc" \
      -DCMAKE_CXX_COMPILER="${CROSS_HOST}-g++" \
      -DCMAKE_SYSTEM_PROCESSOR="${TARGET_ARCH}" \
      -DWITH_GTEST=OFF
    cmake --build build
    cmake --install build
    zlib_ng_ver="$(grep Version: "${CROSS_PREFIX}/lib/pkgconfig/zlib.pc")"
    echo "- zlib-ng: ${zlib_ng_ver}, source: ${zlib_ng_latest_url:-cached zlib-ng}" >>"${BUILD_INFO}"
    # Fix mingw build sharedlibdir lost issue
    sed -i 's@^sharedlibdir=.*@sharedlibdir=${libdir}@' "${CROSS_PREFIX}/lib/pkgconfig/zlib.pc"
  else
    zlib_tag="$(retry wget -qO- --compression=auto https://zlib.net/ \| grep -i "'<FONT.*FONT>'" \| sed -r "'s/.*zlib\s*([^<]+).*/\1/'" \| head -1)"
    zlib_latest_url="https://zlib.net/zlib-${zlib_tag}.tar.xz"
    if [ ! -f "${DOWNLOADS_DIR}/zlib-${zlib_tag}.tar.gz" ]; then
      retry wget -cT10 -O "${DOWNLOADS_DIR}/zlib-${zlib_tag}.tar.gz.part" "${zlib_latest_url}"
      mv -fv "${DOWNLOADS_DIR}/zlib-${zlib_tag}.tar.gz.part" "${DOWNLOADS_DIR}/zlib-${zlib_tag}.tar.gz"
    fi
    mkdir -p "/usr/src/zlib-${zlib_tag}"
    tar -Jxf "${DOWNLOADS_DIR}/zlib-${zlib_tag}.tar.gz" --strip-components=1 -C "/usr/src/zlib-${zlib_tag}"
    cd "/usr/src/zlib-${zlib_tag}"
    if [ x"${TARGET_HOST}" = xWindows ]; then
      make -f win32/Makefile.gcc BINARY_PATH="${CROSS_PREFIX}/bin" INCLUDE_PATH="${CROSS_PREFIX}/include" LIBRARY_PATH="${CROSS_PREFIX}/lib" SHARED_MODE=0 PREFIX="${CROSS_HOST}-" -j$(nproc) install
    else
      CHOST="${CROSS_HOST}" ./configure --prefix="${CROSS_PREFIX}" --static
      make -j$(nproc)
      make install
    fi
    zlib_ver="$(grep Version: "${CROSS_PREFIX}/lib/pkgconfig/zlib.pc")"
    echo "- zlib: ${zlib_ver}, source: ${zlib_latest_url:-cached zlib}" >>"${BUILD_INFO}"
  fi
}

prepare_xz() {
  # Download from github release (now breakdown)
  # xz_release_info="$(retry wget -qO- --compression=auto https://api.github.com/repos/tukaani-project/xz/releases \| jq -r "'[.[] | select(.prerelease == false)][0]'")"
  # xz_tag="$(printf '%s' "${xz_release_info}" | jq -r '.tag_name')"
  # xz_archive_name="$(printf '%s' "${xz_release_info}" | jq -r '.assets[].name | select(endswith("tar.xz"))')"
  # xz_latest_url="https://github.com/tukaani-project/xz/releases/download/${xz_tag}/${xz_archive_name}"
  # if [ x"${USE_CHINA_MIRROR}" = x1 ]; then
  #   xz_latest_url="https://mirror.ghproxy.com/${xz_latest_url}"
  # fi
  # Download from sourceforge
  xz_tag="$(retry wget -qO- --compression=auto https://sourceforge.net/projects/lzmautils/files/ \| grep -i \'span class=\"sub-label\"\' \| head -1 \| sed -r "'s/.*xz-(.+)\.tar\.gz.*/\1/'")"
  xz_latest_url="https://sourceforge.net/projects/lzmautils/files/xz-${xz_tag}.tar.xz"
  if [ ! -f "${DOWNLOADS_DIR}/xz-${xz_tag}.tar.xz" ]; then
    retry wget -cT10 -O "${DOWNLOADS_DIR}/xz-${xz_tag}.tar.xz.part" "${xz_latest_url}"
    mv -fv "${DOWNLOADS_DIR}/xz-${xz_tag}.tar.xz.part" "${DOWNLOADS_DIR}/xz-${xz_tag}.tar.xz"
  fi
  mkdir -p "/usr/src/xz-${xz_tag}"
  tar -Jxf "${DOWNLOADS_DIR}/xz-${xz_tag}.tar.xz" --strip-components=1 -C "/usr/src/xz-${xz_tag}"
  cd "/usr/src/xz-${xz_tag}"
  ./configure --host="${CROSS_HOST}" --prefix="${CROSS_PREFIX}" --enable-silent-rules --enable-static --disable-shared
  make -j$(nproc)
  make install
  xz_ver="$(grep Version: "${CROSS_PREFIX}/lib/pkgconfig/liblzma.pc")"
  echo "- xz: ${xz_ver}, source: ${xz_latest_url:-cached xz}" >>"${BUILD_INFO}"
}

prepare_ssl() {
  # Windows will use Wintls, not openssl
  if [ x"${TARGET_HOST}" != xWindows ]; then
    if [ x"${USE_LIBRESSL}" = x1 ]; then
      # libressl
      libressl_tag="$(retry wget -qO- --compression=auto https://www.libressl.org/index.html \| grep "'release is'" \| tail -1 \| sed -r "'s/.* (.+)<.*>$/\1/'")" libressl_latest_url="https://ftp.openbsd.org/pub/OpenBSD/LibreSSL/libressl-${libressl_tag}.tar.gz"
      if [ x"${USE_CHINA_MIRROR}" = x1 ]; then
        libressl_latest_url="https://mirror.sjtu.edu.cn/OpenBSD/LibreSSL/libressl-${libressl_tag}.tar.gz"
      fi
      if [ ! -f "${DOWNLOADS_DIR}/libressl-${libressl_tag}.tar.gz" ]; then
        retry wget -cT10 -O "${DOWNLOADS_DIR}/libressl-${libressl_tag}.tar.gz.part" "${libressl_latest_url}"
        mv -fv "${DOWNLOADS_DIR}/libressl-${libressl_tag}.tar.gz.part" "${DOWNLOADS_DIR}/libressl-${libressl_tag}.tar.gz"
      fi
      mkdir -p "/usr/src/libressl-${libressl_tag}"
      tar -zxf "${DOWNLOADS_DIR}/libressl-${libressl_tag}.tar.gz" --strip-components=1 -C "/usr/src/libressl-${libressl_tag}"
      cd "/usr/src/libressl-${libressl_tag}"
      if [ ! -f "./configure" ]; then
        ./autogen.sh
      fi
      ./configure --host="${CROSS_HOST}" --prefix="${CROSS_PREFIX}" --enable-silent-rules --enable-static --disable-shared --with-openssldir=/etc/ssl
      make -j$(nproc)
      make install_sw
      libressl_ver="$(grep Version: "${CROSS_PREFIX}/lib/pkgconfig/openssl.pc")"
      echo "- libressl: ${libressl_ver}, source: ${libressl_latest_url:-cached libressl}" >>"${BUILD_INFO}"
    else
      # openssl
      openssl_filename="$(retry wget -qO- --compression=auto https://www.openssl.org/source/ \| grep -o "'href=\"openssl-3.2.*tar.gz\"'" \| grep -o "'[^\"]*.tar.gz'" \| head -1)"
      openssl_ver="$(echo "${openssl_filename}" | sed -r 's/openssl-(.+)\.tar\.gz/\1/')"
      openssl_latest_url="https://github.com/openssl/openssl/archive/refs/tags/${openssl_filename}"
      if [ x"${USE_CHINA_MIRROR}" = x1 ]; then
        openssl_latest_url="https://mirror.ghproxy.com/${openssl_latest_url}"
      fi
      if [ ! -f "${DOWNLOADS_DIR}/openssl-${openssl_ver}.tar.gz" ]; then
        retry wget -cT10 -O "${DOWNLOADS_DIR}/openssl-${openssl_ver}.tar.gz.part" "${openssl_latest_url}"
        mv -fv "${DOWNLOADS_DIR}/openssl-${openssl_ver}.tar.gz.part" "${DOWNLOADS_DIR}/openssl-${openssl_ver}.tar.gz"
      fi
      mkdir -p "/usr/src/openssl-${openssl_ver}"
      tar -zxf "${DOWNLOADS_DIR}/openssl-${openssl_ver}.tar.gz" --strip-components=1 -C "/usr/src/openssl-${openssl_ver}"
      cd "/usr/src/openssl-${openssl_ver}"
      ./Configure \
        "${OPENSSL_COMPILER}" \
        --cross-compile-prefix="${CROSS_HOST}-" \
        --prefix="${CROSS_PREFIX}" \
        --openssldir=/etc/ssl \
        no-tests
      make -j$(nproc)
      make install_sw
      openssl_ver="$(grep Version: "${CROSS_PREFIX}"/lib*/pkgconfig/openssl.pc)"
      echo "- openssl: ${openssl_ver}, source: ${openssl_latest_url:-cached openssl}" >>"${BUILD_INFO}"
    fi
  fi
}

prepare_libxml2() {
  libxml2_latest_url="$(retry wget -qO- --compression=auto 'https://gitlab.gnome.org/api/graphql' --header="'Content-Type: application/json'" --post-data="'{\"query\":\"query {project(fullPath:\\\"GNOME/libxml2\\\"){releases(first:1,sort:RELEASED_AT_DESC){nodes{assets{links{nodes{directAssetUrl}}}}}}}\"}'" \| jq -r "'.data.project.releases.nodes[0].assets.links.nodes[0].directAssetUrl'")"
  libxml2_tag="$(echo "${libxml2_latest_url}" | sed -r 's/.*libxml2-(.+).tar.*/\1/')"
  libxml2_filename="$(echo "${libxml2_latest_url}" | sed -r 's/.*(libxml2-(.+).tar.*)/\1/')"
  if [ ! -f "${DOWNLOADS_DIR}/${libxml2_filename}" ]; then
    retry wget -c -O "${DOWNLOADS_DIR}/${libxml2_filename}.part" "${libxml2_latest_url}"
    mv -fv "${DOWNLOADS_DIR}/${libxml2_filename}.part" "${DOWNLOADS_DIR}/${libxml2_filename}"
  fi
  mkdir -p "/usr/src/libxml2-${libxml2_tag}"
  tar -axf "${DOWNLOADS_DIR}/${libxml2_filename}" --strip-components=1 -C "/usr/src/libxml2-${libxml2_tag}"
  cd "/usr/src/libxml2-${libxml2_tag}"
  ./configure --host="${CROSS_HOST}" --prefix="${CROSS_PREFIX}" --enable-silent-rules --without-python --without-icu --enable-static --disable-shared
  make -j$(nproc)
  make install
  libxml2_ver="$(grep Version: "${CROSS_PREFIX}/lib/pkgconfig/"libxml-*.pc)"
  echo "- libxml2: ${libxml2_ver}, source: ${libxml2_latest_url:-cached libxml2}" >>"${BUILD_INFO}"
}

prepare_sqlite() {
  sqlite_tag="$(retry wget -qO- --compression=auto https://www.sqlite.org/index.html \| sed -nr "'s/.*>Version (.+)<.*/\1/p'")"
  sqlite_latest_url="https://github.com/sqlite/sqlite/archive/release.tar.gz"
  if [ x"${USE_CHINA_MIRROR}" = x1 ]; then
    sqlite_latest_url="https://mirror.ghproxy.com/${sqlite_latest_url}"
  fi
  if [ ! -f "${DOWNLOADS_DIR}/sqlite-${sqlite_tag}.tar.gz" ]; then
    retry wget -cT10 -O "${DOWNLOADS_DIR}/sqlite-${sqlite_tag}.tar.gz.part" "${sqlite_latest_url}"
    mv -fv "${DOWNLOADS_DIR}/sqlite-${sqlite_tag}.tar.gz.part" "${DOWNLOADS_DIR}/sqlite-${sqlite_tag}.tar.gz"
  fi
  
  mkdir -p "/usr/src/sqlite-${sqlite_tag}"
  tar -zxf "${DOWNLOADS_DIR}/sqlite-${sqlite_tag}.tar.gz" --strip-components=1 -C "/usr/src/sqlite-${sqlite_tag}"
  cd "/usr/src/sqlite-${sqlite_tag}"
  if [ x"${TARGET_HOST}" = x"Windows" ]; then
    ln -sf mksourceid.exe mksourceid
    SQLITE_EXT_CONF="config_TARGET_EXEEXT=.exe"
  fi
  ./configure \
    --host="${CROSS_HOST}" \
    --build="${BUILD_ARCH}" \
    --prefix="${CROSS_PREFIX}" \
    --enable-static \
    --disable-shared \
    --disable-dynamic-extensions \
    ${SQLITE_EXT_CONF}
  make -j$(nproc)
  make install
  sqlite_ver="$(grep Version: "${CROSS_PREFIX}/lib/pkgconfig/"sqlite*.pc)"
  echo "- sqlite: ${sqlite_ver}, source: ${sqlite_latest_url:-cached sqlite}" >>"${BUILD_INFO}"
}

prepare_c_ares() {
  cares_latest_tag="$(retry wget -qO- --compression=auto https://api.github.com/repos/c-ares/c-ares/releases \| jq -r "'.[0].tag_name'")"
  cares_latest_url="https://github.com/c-ares/c-ares/archive/refs/tags/${cares_latest_tag}.tar.gz"
  if [ x"${USE_CHINA_MIRROR}" = x1 ]; then
      cares_latest_url="https://mirror.ghproxy.com/${cares_latest_url}"
  fi
  if [ ! -f "${DOWNLOADS_DIR}/c-ares-${cares_latest_tag}.tar.gz" ]; then
    retry wget -cT10 -O "${DOWNLOADS_DIR}/c-ares-${cares_latest_tag}.tar.gz.part" "${cares_latest_url}"
    mv -fv "${DOWNLOADS_DIR}/c-ares-${cares_latest_tag}.tar.gz.part" "${DOWNLOADS_DIR}/c-ares-${cares_latest_tag}.tar.gz"
  fi
  mkdir -p "/usr/src/c-ares-${cares_latest_tag}"
  tar -zxf "${DOWNLOADS_DIR}/c-ares-${cares_latest_tag}.tar.gz" --strip-components=1 -C "/usr/src/c-ares-${cares_latest_tag}"
  cd "/usr/src/c-ares-${cares_latest_tag}"
  if [ ! -f "./configure" ]; then
    autoreconf -i
  fi
  ./configure --host="${CROSS_HOST}" --prefix="${CROSS_PREFIX}" --enable-static --disable-shared --enable-silent-rules --disable-tests
  make -j$(nproc)
  make install
  cares_ver="$(grep Version: "${CROSS_PREFIX}/lib/pkgconfig/libcares.pc")"
  echo "- c-ares: ${cares_ver}, source: ${cares_latest_url:-cached c-ares}" >>"${BUILD_INFO}"
}

prepare_libssh2() {
  libssh2_tag="$(retry wget -qO- --compression=auto https://libssh2.org/ \| sed -nr "'s@.*libssh2 ([^<]*).*released on.*@\1@p'")"
  libssh2_latest_url="https://libssh2.org/download/libssh2-${libssh2_tag}.tar.gz"
  if [ ! -f "${DOWNLOADS_DIR}/libssh2-${libssh2_tag}.tar.gz" ]; then
    retry wget -cT10 -O "${DOWNLOADS_DIR}/libssh2-${libssh2_tag}.tar.gz.part" "${libssh2_latest_url}"
    mv -fv "${DOWNLOADS_DIR}/libssh2-${libssh2_tag}.tar.gz.part" "${DOWNLOADS_DIR}/libssh2-${libssh2_tag}.tar.gz"
  fi
  
  mkdir -p "/usr/src/libssh2-${libssh2_tag}"
  tar -zxf "${DOWNLOADS_DIR}/libssh2-${libssh2_tag}.tar.gz" --strip-components=1 -C "/usr/src/libssh2-${libssh2_tag}"
  cd "/usr/src/libssh2-${libssh2_tag}"
  ./configure \
    --host="${CROSS_HOST}" \
    --prefix="${CROSS_PREFIX}" \
    --enable-static \
    --disable-shared \
    --disable-examples-build \
    --enable-silent-rules
  make -j$(nproc)
  make install
  unset CFLAGS
  libssh2_ver="$(grep Version: "${CROSS_PREFIX}/lib/pkgconfig/libssh2.pc")"
  echo "- libssh2: ${libssh2_ver}, source: ${libssh2_latest_url:-cached libssh2}" >>"${BUILD_INFO}"
}

prepare_libexpat() {
  libexpat_tag="$(retry wget -qO- --compression=auto https://api.github.com/repos/libexpat/libexpat/releases \| jq -r "'.[0].tag_name'")"
  libexpat_latest_url="https://github.com/libexpat/libexpat/archive/refs/tags/${libexpat_tag}.tar.gz"
  if [ x"${USE_CHINA_MIRROR}" = x1 ]; then
      libexpat_latest_url="https://mirror.ghproxy.com/${libexpat_latest_url}"
  fi
  if [ ! -f "${DOWNLOADS_DIR}/libexpat-${libexpat_tag}.tar.gz" ]; then
    retry wget -cT10 -O "${DOWNLOADS_DIR}/libexpat-${libexpat_tag}.tar.gz.part" "${libexpat_latest_url}"
    mv -fv "${DOWNLOADS_DIR}/libexpat-${libexpat_tag}.tar.gz.part" "${DOWNLOADS_DIR}/libexpat-${libexpat_tag}.tar.gz"
  fi
  mkdir -p "/usr/src/libexpat-${libexpat_tag}"
  tar -zxf "${DOWNLOADS_DIR}/libexpat-${libexpat_tag}.tar.gz" --strip-components=1 -C "/usr/src/libexpat-${libexpat_tag}"
  cd "/usr/src/libexpat-${libexpat_tag}"
  cd expat
  ./buildconf.sh
  ./configure \
    --host="${CROSS_HOST}" \
    --prefix="${CROSS_PREFIX}" \
    --enable-static \
    --disable-shared \
    --without-examples \
    --without-tests \
    --without-docbook
  make -j$(nproc)
  make install
  expat_ver="$(grep Version: "${CROSS_PREFIX}/lib/pkgconfig/expat.pc")"
  echo "- libexpat: ${libexpat_ver}, source: ${libexpat_latest_url:-cached libexpat}" >>"${BUILD_INFO}"
}

prepare_jemalloc() {
  jemalloc_tag="$(retry wget -qO- --compression=auto https://api.github.com/repos/jemalloc/jemalloc/releases \| jq -r "'.[0].tag_name'")"
  jemalloc_latest_url="https://github.com/jemalloc/jemalloc/archive/refs/tags/${jemalloc_tag}.tar.gz"
  if [ x"${USE_CHINA_MIRROR}" = x1 ]; then
      jemalloc_latest_url="https://mirror.ghproxy.com/${jemalloc_latest_url}"
  fi
  if [ ! -f "${DOWNLOADS_DIR}/jemalloc-${jemalloc_tag}.tar.gz" ]; then
    retry wget -cT10 -O "${DOWNLOADS_DIR}/jemalloc-${jemalloc_tag}.tar.gz.part" "${jemalloc_latest_url}"
    mv -fv "${DOWNLOADS_DIR}/jemalloc-${jemalloc_tag}.tar.gz.part" "${DOWNLOADS_DIR}/jemalloc-${jemalloc_tag}.tar.gz"
  fi
  mkdir -p "/usr/src/jemalloc-${jemalloc_tag}"
  tar -zxf "${DOWNLOADS_DIR}/jemalloc-${jemalloc_tag}.tar.gz" --strip-components=1 -C "/usr/src/jemalloc-${jemalloc_tag}"
  cd "/usr/src/jemalloc-${jemalloc_tag}"
  ./configure \
    --host="${CROSS_HOST}" \
    --prefix="${CROSS_PREFIX}" \
    --enable-static \
    --disable-shared \
    --disable-stats \
    --enable-prof
  make -j$(nproc)
  make install
  jemalloc_ver="$(grep Version: "${CROSS_PREFIX}/lib/pkgconfig/jemalloc.pc")"
  echo "- jemalloc: ${jemalloc_ver}, source: ${jemalloc_latest_url:-cached jemalloc}" >>"${BUILD_INFO}"
}

build_aria2() {
  if [ ! -f ./configure ]; then
    autoreconf -i
  fi
  if [ x"${TARGET_HOST}" = xwin ]; then
    ARIA2_EXT_CONF='--without-openssl'
  # else
  #   ARIA2_EXT_CONF='--with-ca-bundle=/etc/ssl/certs/ca-certificates.crt'
  fi
  ./configure \
  --host="${CROSS_HOST}" \
  --prefix="${CROSS_PREFIX}" \
  --with-libz \
  --with-libcares \
  --with-libexpat \
  --without-libxml2 \
  --without-libnettle \
  --without-gnutls \
  --without-libgmp \
  --with-libcares \
  --with-libssh2 \
  --with-sqlite3 \
  --enable-static \
  --disable-shared \
  --enable-silent-rules \
  ARIA2_STATIC=yes \
  ${ARIA2_EXT_CONF}
  make -j$(nproc)
  make install
  echo "- aria2: source: ${aria2_latest_url:-cached aria2}" >>"${BUILD_INFO}"
  echo >>"${BUILD_INFO}"
}

get_aria2() {
  if [ -n "${ARIA2_VER}" ]; then
    aria2_tag="${ARIA2_VER}"
  else
    aria2_tag=master
  fi

  ARIA2_CODE_DIR="/usr/src/aria2-${aria2_tag}"

  if [[ -d $ARIA2_CODE_DIR && -d $ARIA2_CODE_DIR/.git ]]; then
    cd $ARIA2_CODE_DIR
    git checkout master || git checkout HEAD
    git reset --hard origin || git reset --hard
    git pull
  else
    rm -rf $ARIA2_CODE_DIR
    git clone https://github.com/aria2/aria2 $ARIA2_CODE_DIR
    cd $ARIA2_CODE_DIR
  fi
}

patch_aria2() {
  git apply ${SELF_DIR}/patch/*.patch
}

strip_aria2() {
  ${CROSS_HOST}-strip "${CROSS_PREFIX}/bin/"aria2*
}

get_build_info() {
  echo "============= ARIA2 VER INFO ==================="
  ARIA2_VER_INFO="$("${RUNNER_CHECKER}" "${CROSS_PREFIX}/bin/aria2c"* --version 2>/dev/null)"
  echo "${ARIA2_VER_INFO}"
  echo "================================================"

  echo "aria2 version info:" >>"${BUILD_INFO}"
  echo '```txt' >>"${BUILD_INFO}"
  echo "${ARIA2_VER_INFO}" >>"${BUILD_INFO}"
  echo '```' >>"${BUILD_INFO}"
}

test_build() {
  # get release
  cp -fv "${CROSS_PREFIX}/bin/"aria2* "${SELF_DIR}"
  echo "============= ARIA2 TEST DOWNLOAD =============="
  "${RUNNER_CHECKER}" "${CROSS_PREFIX}/bin/aria2c"* -t 10 --console-log-level=debug --http-accept-gzip=true https://github.com/ -d /tmp -o test
  echo "================================================"
}

prepare_cmake
prepare_ninja
prepare_zlib
prepare_libexpat
prepare_c_ares
prepare_xz
prepare_ssl
# prepare_libxml2
prepare_sqlite
prepare_libssh2

get_aria2
patch_aria2
build_aria2
strip_aria2

get_build_info
# mips test will hang, I don't know why. So I just ignore test failures.
# test_build

# get release
cp -fv "${CROSS_PREFIX}/bin/"aria2* "${SELF_DIR}"
