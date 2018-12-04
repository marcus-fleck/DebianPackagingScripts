#!/bin/bash -e

PACKAGE="$1"
if [ -z "${PACKAGE}" ]; then
  echo "Usage: ./uplodatePackageToPPA.sh <packageName>"
  exit 1
fi

WD=`dirname $0`
cd "$WD"

# Use the currently by-default used codename when building packages with the master script. We will extract the build information from there.
REFERENCE_CODENAME=xenial

# Update DebianBuildVersions
if [ ! -d "DebianBuildVersions/.git" ]; then
  git clone https://github.com/ChimeraTK/DebianBuildVersions
else 
  cd DebianBuildVersions
  git pull
  cd ..
fi

# Check if package is known
if [ ! -f "DebianBuildVersions/${PACKAGE}/CONFIG" ]; then
  echo "'DebianBuildVersions/${PACKAGE}/CONFIG' not found. Is '${PACKAGE}' a valid package name?"
  exit 1
fi

echo "Working on package '${PACKAGE}'..."

# Obtain source URI and dirname
SourceURI=`grep "^SourceURI:" "DebianBuildVersions/${PACKAGE}/CONFIG" | sed -e 's/SourceURI: *//'`
SourceBaseName="`basename "${SourceURI}"`"

# Update source tree
if [ ! -d "${SourceBaseName}/.git" ]; then
  git clone ${SourceURI}
else
  cd "${SourceBaseName}"
  git fetch
  cd ..
fi

# Find latest build in DebianBuildVersions
LAST_BUILD_FILE=`find "DebianBuildVersions/${PACKAGE}" -name LAST_BUILD | sort | tail -n1`
LAST_BUILD_PATH=`cat "${LAST_BUILD_FILE}"`
LAST_BUILD_NUMBER=`cat "DebianBuildVersions/${LAST_BUILD_PATH}/BUILD_NUMBER"`

# Determine the tag and check it out
SOURCE_VERSION_NOPATCH=`echo "${LAST_BUILD_FILE}" | sed -e "s_^DebianBuildVersions/${PACKAGE}/__" -e 's_/.*$__'`
cd "${SourceBaseName}"
SOURCE_VERSION=`git tag | grep "^${SOURCE_VERSION_NOPATCH}" | sort | tail -n1`
echo "Using source version $SOURCE_VERSION"
git checkout ${SOURCE_VERSION}
cd ..

# Copy Debian control files from the build
LAST_BUILD_DIR="`dirname ${LAST_BUILD_FILE}`/${LAST_BUILD_NUMBER}"
mkdir -p "${SourceBaseName}/debian"
cp -r "${LAST_BUILD_DIR}"/* "${SourceBaseName}/debian"

# Hack the control file to be independent of the Ubuntu version and the exact build: remove all build-dependency version numbers
rm -f "${SourceBaseName}/debian/control-new"
touch "${SourceBaseName}/debian/control-new"
while read line; do
  line_new=""
  IFS=','
  for token in $line ; do
    IFS=' '
    # does the token contain a ChimeraTK build version (i.e. contain 'xenial')? -> replace 'xenial' with 'ubuntu'
    # otherwise remove everything within parenthesis
    if [[ "$token" == *"xenial"* ]]; then
      token="`echo "$token" | sed -e 's/xenial/ubuntu/'`"
    else
      token="`echo "$token" | sed -e 's/ ([^)]*)//'`"
    fi
    if [ -z "${line_new}" ]; then
      line_new="${token}"
    else
      line_new="${line_new},${token}"
    fi
  done
  echo ${line_new} >> "${SourceBaseName}/debian/control-new"
done < "${SourceBaseName}/debian/control"
mv "${SourceBaseName}/debian/control-new" "${SourceBaseName}/debian/control"

# Hack the rules file to set the build version
sed -i "${SourceBaseName}/debian/rules" -e 's,^#!/usr/bin/make -f$,#!/usr/bin/make -f\nexport PROJECT_BUILDVERSION=ubuntu'${LAST_BUILD_NUMBER}','

# initialise bazaar working copy if not yet done
cd "${SourceBaseName}"
if [ ! -d .bzr ]; then
  bzr init
fi

# check if anything modified. if not, we are done
if [ `bzr status | wc -l` -eq 0 ]; then
  echo "*** No changes, nothing to commit."
  exit 0
fi

# generate changelog file
SOURCE_PACKAGE=`grep "^Source:" "debian/control" | sed -e 's/^Source: *//'`
debchange --create --package ${SOURCE_PACKAGE} -v ${SOURCE_VERSION} "Automated preparation for the PPA"

# Commit everything to launchpad
bzr add .
bzr commit -m "Automated commit"
bzr push lp:~chimeratk/chimeratk/${SOURCE_PACKAGE}-package
