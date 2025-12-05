#!/bin/bash

# Generate the sources.list.<arch> in the config path
CONFIG_PATH=$1
export ARCHITECTURE=$2
export DISTRIBUTION=$3
# Debug log path
DEBUG_LOG=${CONFIG_PATH}/build_mirror_config.debug.log

# Force bookworm for docker-base-bookworm arm64 builds regardless of passed-in distro
if [ "$ARCHITECTURE" = "arm64" ] && [[ "$CONFIG_PATH" == *"docker-base-bookworm"* ]]; then
    DISTRIBUTION=bookworm
fi

# Handling default
[[ -z $APT_RETRIES_COUNT ]] && APT_RETRIES_COUNT=20
export APT_RETRIES_COUNT

DEFAULT_MIRROR_URL_PREFIX=http://packages.trafficmanager.net
MIRROR_VERSION_FILE=
[[ "$MIRROR_SNAPSHOT" == "y" ]] && MIRROR_VERSION_FILE=files/build/versions/default/versions-mirror
[ -f target/versions/default/versions-mirror ] && MIRROR_VERSION_FILE=target/versions/default/versions-mirror

# Init debug log
{
    echo "==== build_mirror_config.sh debug ===="
    echo "CONFIG_PATH=$CONFIG_PATH"
    echo "ARCHITECTURE=$ARCHITECTURE"
    echo "DISTRIBUTION=$DISTRIBUTION"
    echo "MIRROR_URLS(env)=$MIRROR_URLS"
    echo "MIRROR_SECURITY_URLS(env)=$MIRROR_SECURITY_URLS"
    echo "MIRROR_SNAPSHOT=$MIRROR_SNAPSHOT"
    echo "MIRROR_VERSION_FILE=$MIRROR_VERSION_FILE"
    echo "DEFAULT_MIRROR_URL_PREFIX=$DEFAULT_MIRROR_URL_PREFIX"
} > $DEBUG_LOG

# The default mirror urls
DEFAULT_MIRROR_URLS=http://debian-archive.trafficmanager.net/debian/
DEFAULT_MIRROR_SECURITY_URLS=http://debian-archive.trafficmanager.net/debian-security/

# If distribution is empty and we are building docker-base-bookworm, force bookworm to avoid jessie fallback
if [[ -z "$DISTRIBUTION" && "$CONFIG_PATH" == *"docker-base-bookworm"* ]]; then
    DISTRIBUTION=bookworm
fi
# If distribution is still empty and architecture is arm64, default to bookworm to avoid jessie fallback
if [ -z "$DISTRIBUTION" ] && [ "$ARCHITECTURE" = "arm64" ]; then
    DISTRIBUTION=bookworm
fi


# The debian-archive.trafficmanager.net does not support armhf, use debian.org instead
if [ "$ARCHITECTURE" == "armhf" ]; then
    DEFAULT_MIRROR_URLS=http://deb.debian.org/debian/
    DEFAULT_MIRROR_SECURITY_URLS=http://deb.debian.org/debian-security/
fi

# For arm64 bookworm builds, force official deb.debian.org to avoid stale jessie mirrors
if [ "$ARCHITECTURE" == "arm64" ] && [ "$DISTRIBUTION" == "bookworm" ]; then
    DEFAULT_MIRROR_URLS=http://deb.debian.org/debian/
    DEFAULT_MIRROR_SECURITY_URLS=http://deb.debian.org/debian-security/
fi

if [ "$DISTRIBUTION" == "buster" ] || [ "$DISTRIBUTION" == "bullseye" ]; then
    DEFAULT_MIRROR_URLS=http://archive.debian.org/debian/
fi

if [ "$MIRROR_SNAPSHOT" == y ]; then
    if [ -f "$MIRROR_VERSION_FILE" ]; then
        DEBIAN_TIMESTAMP=$(grep "^debian==" $MIRROR_VERSION_FILE | tail -n 1 | sed 's/.*==//')
        DEBIAN_SECURITY_TIMESTAMP=$(grep "^debian-security==" $MIRROR_VERSION_FILE | tail -n 1 | sed 's/.*==//')
    elif [ -z "$DEBIAN_TIMESTAMP" ] || [ -z "$DEBIAN_SECURITY_TIMESTAMP" ]; then
        DEBIAN_TIMESTAMP=$(curl $DEFAULT_MIRROR_URL_PREFIX/snapshot/debian/latest/timestamp)
        DEBIAN_SECURITY_TIMESTAMP=$(curl $DEFAULT_MIRROR_URL_PREFIX/snapshot/debian-security/latest/timestamp)
    fi

    DEFAULT_MIRROR_URLS=http://deb.debian.org/debian/,http://packages.trafficmanager.net/snapshot/debian/$DEBIAN_TIMESTAMP/
    DEFAULT_MIRROR_SECURITY_URLS=http://deb.debian.org/debian-security/,http://packages.trafficmanager.net/snapshot/debian-security/$DEBIAN_SECURITY_TIMESTAMP/

	if [ "$DISTRIBUTION" == "buster" ] || [ "$DISTRIBUTION" == "bullseye" ]; then
		DEFAULT_MIRROR_URLS=http://archive.debian.org/debian/,http://packages.trafficmanager.net/snapshot/debian/$DEBIAN_TIMESTAMP/
	fi

    mkdir -p target/versions/default
    if [ ! -f target/versions/default/versions-mirror ]; then
        echo "debian==$DEBIAN_TIMESTAMP" > target/versions/default/versions-mirror
        echo "debian-security==$DEBIAN_SECURITY_TIMESTAMP" >> target/versions/default/versions-mirror
    fi
fi

# Handle sources list
[ -z "$MIRROR_URLS" ] && MIRROR_URLS=$DEFAULT_MIRROR_URLS
[ -z "$MIRROR_SECURITY_URLS" ] && MIRROR_SECURITY_URLS=$DEFAULT_MIRROR_SECURITY_URLS
{
    echo "FINAL_DEFAULT_MIRROR_URLS=$DEFAULT_MIRROR_URLS"
    echo "FINAL_DEFAULT_SECURITY_URLS=$DEFAULT_MIRROR_SECURITY_URLS"
    echo "FINAL_MIRROR_URLS=$MIRROR_URLS"
    echo "FINAL_MIRROR_SECURITY_URLS=$MIRROR_SECURITY_URLS"
    echo "USING_TEMPLATE=$TEMPLATE"
} >> $DEBUG_LOG

TEMPLATE=files/apt/sources.list.j2
[ -f files/apt/sources.list.$ARCHITECTURE.j2 ] && TEMPLATE=files/apt/sources.list.$ARCHITECTURE.j2
[ -f $CONFIG_PATH/sources.list.j2 ] && TEMPLATE=$CONFIG_PATH/sources.list.j2
[ -f $CONFIG_PATH/sources.list.$ARCHITECTURE.j2 ] && TEMPLATE=$CONFIG_PATH/sources.list.$ARCHITECTURE.j2

echo "SELECTED_TEMPLATE=$TEMPLATE" >> $DEBUG_LOG
MIRROR_URLS=$MIRROR_URLS MIRROR_SECURITY_URLS=$MIRROR_SECURITY_URLS j2 $TEMPLATE | sed '/^$/N;/^\n$/D' > $CONFIG_PATH/sources.list.$ARCHITECTURE
{
    echo "GENERATED_FILE=$CONFIG_PATH/sources.list.$ARCHITECTURE"
    echo "--- CONTENT START ---"
    cat $CONFIG_PATH/sources.list.$ARCHITECTURE
    echo "--- CONTENT END ---"
} >> $DEBUG_LOG
if [ "$MIRROR_SNAPSHOT" == y ]; then
    # Set the snapshot mirror, and add the SET_REPR_MIRRORS flag
    sed -i -e "/^#*deb.*packages.trafficmanager.net/! s/^#*deb/#&/" -e "\$a#SET_REPR_MIRRORS" $CONFIG_PATH/sources.list.$ARCHITECTURE
    echo "SNAPSHOT_POSTPROCESS applied" >> $DEBUG_LOG
fi

# Handle apt retry count config
APT_RETRIES_COUNT_FILENAME=apt-retries-count
TEMPLATE=files/apt/$APT_RETRIES_COUNT_FILENAME.j2
j2 $TEMPLATE > $CONFIG_PATH/$APT_RETRIES_COUNT_FILENAME
{
    echo "GENERATED_APT_RETRIES=$CONFIG_PATH/$APT_RETRIES_COUNT_FILENAME"
    echo "--- APT_RETRIES CONTENT START ---"
    cat $CONFIG_PATH/$APT_RETRIES_COUNT_FILENAME
    echo "--- APT_RETRIES CONTENT END ---"
    echo "==== build_mirror_config.sh debug end ===="
} >> $DEBUG_LOG
