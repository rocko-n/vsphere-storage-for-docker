#!/bin/bash
# Copyright 2016 VMware, Inc. All Rights Reserved.
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#    http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.



# A simple test to validate refcounts.

# Creates $count running containers using a VMDK volume, checks refcount
# by grepping the log (assumes DEBUG log level), touches files within and
# checks the files are all there, Then removes the containers and the volume
#
# *** Caveat: at exit, it kills all containers and cleans all volumes on the box !
# It should just accumulate the names of containers and volumes to clean up.
#
# It should eventually be replaced with a proper test in ../refcnt_test.go.
# For now (TP) we still need basic validation
#

log=/var/log/docker-volume-vsphere.log
count=5
vname=refCountTestVol
mount=/mnt/vmdk/$vname

function cleanup_containers {
   to_kill=`docker ps -q`
   to_rm=`docker ps -a -q`

   if [ -n "$to_kill" -o -n "$to_rm" ]
   then
      echo "Cleaning up containers"
   fi
   if [ -n "$to_kill" ] ; then $DOCKER kill $to_kill > /dev/null ; fi
   if [ -n "$to_rm" ] ; then $DOCKER rm $to_rm > /dev/null; fi
}

function cleanup {
   cleanup_containers
   $DOCKER volume rm $vname
}
trap cleanup EXIT

DOCKER="$DEBUG docker"
GREP="$DEBUG grep"

# Now start the test

echo "Testing refcounts..."

echo "Creating volume $vname and $count containers using it"
$DOCKER volume create --driver=vmdk --name=$vname
echo "$(docker volume ls)"
for i in `seq 1 $count`
do
  $DOCKER run -d -v $vname:/v busybox sh -c "touch /v/file$i; sync ; sleep 60"
done

echo "Checking volume content"
# give OS schedule time to execute the 'touches' from the above docker runs
sleep 5
# now check how many files we see in the still-mounted volume
files=`$DOCKER run -v $vname:/v busybox sh -c 'ls -1 /v/file*'`
c=`echo $files | wc -w`
echo "Found $c files. Expected $count"
if [ $c -ne $count ] ; then
   echo FAILED CONTENT TEST - not enough files in /$vname/file\*
   echo files: \"$files\"
   exit 1
fi

echo "Checking the last refcount and mount record"
last_line=`tail -1 /var/log/docker-volume-vsphere.log`
echo $last_line | $GREP -q refcount=$count ; if [ $? -ne 0 ] ; then
   echo FAILED REFCOUNT TEST - pattern  \"refcount=$count\" not found
   echo Last line in the log: \'$last_line\'
   echo Expected pattern \"refcount=$count\"
   exit 1
fi

$GREP -q $mount /proc/mounts ; if [ $? -ne 0 ] ; then
   echo "FAILED MOUNT TEST 1"
   echo \"$mount\" is not found in /proc/mounts
	exit 1
fi


# should fail 'volume rm', so checking it
echo "Checking 'docker volume rm'"
$DOCKER volume rm $vname 2> /dev/null ; if [ $? -eq 0 ] ; then
   echo FAILED DOCKER RM TEST
   echo  \"docker volume rm $vname\" was expected to fail but succeeded
   exit 1
fi


echo "Checking recovery for VMDK plugin kill -9"
kill -9 `pidof docker-volume-vsphere`
/usr/local/bin/docker-volume-vsphere 2>&1 >/dev/null &
sleep 1; sync  # give log the time to flush
line=`tail -4 /var/log/docker-volume-vsphere.log | $GREP 'Volume name='`
expected="name=$vname count=$count mounted=true"

echo $line | $GREP -q "$expected" ; if [ $? -ne 0 ] ; then
   echo PLUGIN RESTART TEST FAILED. Did not find proper recovery record
   echo Found:  \"$line\"
   echo Expected pattern: \"$expected\"
   exit 1
fi

# kill containers but keep the volume around
cleanup_containers

echo "Checking that the volume is unmounted and can be removed"
$DOCKER volume rm $vname ; if [ $? -ne 0 ] ; then
   echo "FAILED DOCKER RM TEST 2"
   echo \"$DOCKER volume rm $vname\" failed but expected to succeed
   exit 1
fi

$GREP -q $mount /proc/mounts ; if [ $? -eq 0 ] ; then
   echo "FAILED MOUNT TEST "
   echo \"$mount\" found in /proc/mount for an unmounted volume
   exit 1
fi

echo "TEST PASSED."
exit 0