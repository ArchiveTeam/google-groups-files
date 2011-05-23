#!/bin/bash

lastop=0
delay()
{
	thisop=$(date +%s)
	thiswait=$(($RANDOM % 10 + 1))
	thisdelay=$(($thisop - $lastop))
	if test $thisdelay -lt $thiswait;
	then
		echo "Delaying for $thiswait seconds"
		sleep $thiswait
	fi
	lastop=$(date +%s)
}

checkabort()
{
	if test -e /tmp/ggroups-STOP;
	then
		echo STOP file found
		rm /tmp/ggroups-STOP
		exit 0
	fi
}

getdir()
{
	BASE=http://archiveteamorg.appspot.com
	TMP=/tmp/ggroups
	DIRS=$TMP-dirs.$$
	DIR=$TMP-dir.$$
	GRPS=$TMP-grps.$$
	GRPC=$TMP-grpc.$$
	LAST_GRPS=$TMP-lgrps.$$
	DIRS=$TMP-dirs.$$
	WGET_OUT=$TMP-wgetout.$$
	NULL=/dev/null
	
	checkabort
	ret=0
	
	wget -t 3 -O $DIRS $BASE/getdir?n=1 2> $WGET_OUT
	wgetret=$?
	cat $WGET_OUT
	if test $wgetret -ne 0;
	then
		echo Error retrieving a directory URL
		return 2
	fi
	
	echo Processing $DIRS
	echo >> $DIRS
	
	while read gdir
	do
		if test -z $gdir;
		then
			continue
		fi
		checkabort
	
		URL=http://groups.google.com/groups/dir?$gdir
		delay
		
		wget -t 3 -O $DIR $URL
		if test $? -ne 0;
		then
			echo Error retrieving $URL
			return 2
		fi
		
		grep "<a href=\"/groups/dir?" $DIR | sed "s/.*<a href=\"\/groups\/dir?//g;s/\">.*//g" | sort -u > $DIRS
		echo Found $(wc --lines $DIRS) subdirectories

		curl -w 'Uploaded %{size_upload} bytes\n' -T $DIRS $BASE/adddir
		cret=$?
		cat $DIRS | xargs echo dirs:
		if test $cret -ne 0;
		then
			echo Error sending directory $DIRS to the server: $cret
			return 2
		fi
		ret=1

		checkabort
		
		grep -m 1 "<a href=\"/group/" $DIR > /dev/null
		if test $? -eq 1;
		then
			grep "<a class=\"on\" href=\"/group/" $DIR | sed "s/[ ]*<a class=\"on\" href=\"\/group\///g;s/?lnk=\">.*//g" > $GRPS
			echo Found $(wc --lines $GRPS) groups
			echo > $LAST_GRPS
			strt=0
			
			while true;
			do
				diff -q $GRPS $LAST_GRPS > /dev/null
				if test $? -eq 0;
				then
					echo End of dir
					break
				else
					echo Contd. dir: $strt, gdir: $gdir
				fi
				
				curl -w 'Uploaded %{size_upload} bytes\n' -T $GRPS $BASE/addgrp
				cret=$?
				cat $GRPS | xargs echo groups:
				if test $cret -ne 0;
				then
					echo Error sending group name to the server
					return 1
				fi
				
				mv $GRPS $LAST_GRPS
				strt=$(($strt + 15))
				
				wget -t 3 -O $GRPC $URL\&start=$strt
				grep "<a class=\"on\" href=\"/group/" $GRPC | sed "s/[ ]*<a class=\"on\" href=\"\/group\///g;s/?lnk=\">.*//g" > $GRPS
				echo Downloaded $(wc --lines $GRPS) more groups
				
				ret=1
			done
		else
			echo No groups
		fi
		
		wget -t 3 -O $NULL $BASE/donedir?$gdir
	done < $DIRS
	
	return $ret
}

getgrp()
{
	BASE=http://archiveteamorg.appspot.com
	TMP=/tmp/ggroups
	GRP=$TMP-grpname.$$
	NULL=/dev/null
	WGET_OUT=$TMP-wgetout.$$

	checkabort
	wget -t 3 -O $GRP $BASE/getgrp
	if test $? -ne 0;
	then
		echo Error downloading group names
		return 2
	fi
	sed -i "s/[\$/\?;]//g;s/\^.\.//g" $GRP
	
	ret=0
	
	while read grp
	do
		if test -z $grp;
		then
			continue;
		fi
		checkabort

		h=$(echo $grp | md5sum)
		c1=$(echo $h | cut -c 1)
		c2=$(echo $h | cut -c 2)
		c3=$(echo $h | cut -c 3)
		sub=$c1/$c2/$c3
		mkdir -p $sub
		
		echo Downloading $grp
		
		doneg=1
		delay
		wget -t 3 --referer=http://groups.google.com/group/$grp -O $sub/$grp-pages.zip http://groups.google.com/group/$grp/download?s=pages 2> $WGET_OUT
		wgetrc=$?
		cat $WGET_OUT
		if test $wgetrc -ne 0;
		then
			doneg=0
			echo Error downloading $grp-pages.zip
			grep -q "500 Internal Server Error" $WGET_OUT
			if test $? -eq 0;
			then
				wget -t 3 -O $NULL $BASE/errorgrp?g=$grp
			fi
			
			grep -q "403 Forbidden" $WGET_OUT
			if test $? -eq 0;
			then
				wget -t 3 -O $NULL $BASE/donegrp?g=$grp
			fi
				
			grep -q "sorry.google.com" $WGET_OUT
			if test $? -eq 0;
			then
				rm $sub/$grp-pages.zip
				return 2
			fi
		fi
		
		adult=0
		if test -s $sub/$grp-pages.zip;
		then
			grep -s adult_confirm $sub/$grp-pages.zip
			if test $? -eq 0;
			then
				echo $grp is an adult group
				wget -t 3 -O $NULL $BASE/adultgrp?g=$grp
				rm $sub/$grp-pages.zip
				adult=1
				doneg=0
			else
				echo $grp downloaded
			fi
		else
			echo remove $sub/$grp-pages.zip
			rm $sub/$grp-pages.zip
		fi
		
		
		if test $adult -eq 0;
		then
			delay
			wget -t 3 --referer=http://groups.google.com/group/$grp -O $sub/$grp-files.zip http://groups.google.com/group/$grp/download?s=files
			if test $? -ne 0;
			then
				doneg=0
			fi
			
			if test $doneg -eq 1;
			then
				wget -t 3 -O $NULL $BASE/donegrp?g=$grp
			fi

			if test -s $sub/$grp-files.zip;
			then
				echo $grp downloaded
			else
				rm $sub/$grp-files.zip
			fi
		fi
		
		ret=1
	done < $GRP
	
	return $ret
}

mkdir tdir$$
if test $? -ne 0;
then
	echo Cannot create directories
	exit
fi
touch tdir$$/test
if test $? -ne 0;
then
	echo Cannot create test file
	exit
fi
rm -rf tdir$$

which curl > /dev/null
if test $? -ne 0;
then
	echo Error: cannot find curl
	exit 1
fi

do_discover=0
do_download=0
if test x$1 = xdiscover;
then
	do_discover=1
elif test x$1 = xdownload;
then
	do_download=1
else
	do_discover=1
	do_download=1
fi

stime=2
while true;
do
	donef=0
	while test $do_discover -eq 1;
	do
		getdir
		ret=$?
		if test $ret -eq 1;
		then
			stime=2
		else
			if test $ret -eq 0;
			then
				donef=1
			else
				if test $do_download -eq 1;
				then
					break
				else
					echo Error, waiting $stime seconds...
					sleep $stime
					if test $stime -le 856;
					then
						if test $stime -ge 256;
						then
							stime=$(($stime+300))
						else
							stime=$(($stime*$stime))
						fi
					fi					
				fi
			fi
		fi	
	done

	while test $do_download -eq 1;
	do
		getgrp
		ret=$?
		if test $ret -eq 0;
		then
			if test $donef -eq 1;
			then
				echo Done, waiting 30 minutes...
				sleep 1800
				stime=2
			fi
			break
		fi
		if test $ret -eq 2;
		then
			echo Error, waiting $stime seconds...
			sleep $stime
			if test $stime -le 856;
			then
				if test $stime -ge 256;
				then
					stime=$(($stime+300))
				else
					stime=$(($stime*$stime))
				fi
			fi
		fi
		if test $ret -eq 1;
		then
			stime=2
		fi	
	done
done
