#!/system/bin/sh

LOGFILE=/cache/magisk.log
IMG=/data/magisk.img

MOUNTPOINT=/magisk

COREDIR=$MOUNTPOINT/.core

TMPDIR=/dev/magisk
DUMMDIR=$TMPDIR/dummy
MIRRDIR=$TMPDIR/mirror
MOUNTINFO=$TMPDIR/mnt

# Use the included busybox for maximum compatibility and reliable results
# e.g. we rely on the option "-c" for cp (reserve contexts), and -exec for find
TOOLPATH=/data/busybox

# Legacy support for old phh, we don't change PATH now
export OLDPATH=$PATH


log_print() {
  echo "$1"
  echo "$1" >> $LOGFILE
  log -p i -t Magisk "$1"
}

mktouch() {
  mkdir -p ${1%/*} 2>/dev/null
  if [ -z "$2" ]; then
    touch $1 2>/dev/null
  else
    echo $2 > $1 2>/dev/null
  fi
}

unblock() {
  touch /dev/.magisk.unblock
  exit
}

run_scripts() {
  BASE=$MOUNTPOINT
  for MOD in $BASE/* ; do
    if [ ! -f "$MOD/disable" ]; then
      if [ -f "$MOD/$1.sh" ]; then
        chmod 755 $MOD/$1.sh
        chcon 'u:object_r:system_file:s0' $MOD/$1.sh
        log_print "$1: $MOD/$1.sh"
        sh $MOD/$1.sh
      fi
    fi
  done
}

loopsetup() {
  LOOPDEVICE=
  for DEV in $(ls /dev/block/loop*); do
    if [ `$TOOLPATH/losetup $DEV $1 >/dev/null 2>&1; echo $?` -eq 0 ]; then
      LOOPDEVICE=$DEV
      break
    fi
  done
}

target_size_check() {
  e2fsck -p -f $1
  curBlocks=`e2fsck -n $1 2>/dev/null | cut -d, -f3 | cut -d\  -f2`;
  curUsedM=$((`echo "$curBlocks" | cut -d/ -f1` * 4 / 1024));
  curSizeM=$((`echo "$curBlocks" | cut -d/ -f2` * 4 / 1024));
  curFreeM=$((curSizeM - curUsedM));
}

travel() {
  cd $1/$2
  if [ -f ".replace" ]; then
    rm -rf $MOUNTINFO/$2
    mktouch $MOUNTINFO/$2 $1
  else
    for ITEM in * ; do
      if [ ! -e "/$2/$ITEM" ]; then
        # New item found
        if [ $2 = "system" ]; then
          # We cannot add new items to /system root, delete it
          rm -rf $ITEM
        else
          if [ -d "$MOUNTINFO/dummy/$2" ]; then
            # We are in a higher level, delete the lower levels
            rm -rf $MOUNTINFO/dummy/$2
          fi
          # Mount the dummy parent
          mktouch $MOUNTINFO/dummy/$2

          mkdir -p $DUMMDIR/$2 2>/dev/null
          if [ -d "$ITEM" ]; then
            # Create new dummy directory
            mkdir -p $DUMMDIR/$2/$ITEM
          elif [ -L "$ITEM" ]; then
            # Symlinks are small, copy them
            $TOOLPATH/cp -afc $ITEM $DUMMDIR/$2/$ITEM
          else
            # Create new dummy file
            mktouch $DUMMDIR/$2/$ITEM
          fi

          # Clone the original /system structure (depth 1)
          if [ -e "/$2" ]; then
            for DUMMY in /$2/* ; do
              if [ -d "$DUMMY" ]; then
                # Create dummy directory
                mkdir -p $DUMMDIR$DUMMY
              elif [ -L "$DUMMY" ]; then
                # Symlinks are small, copy them
                $TOOLPATH/cp -afc $DUMMY $DUMMDIR$DUMMY
              else
                # Create dummy file
                mktouch $DUMMDIR$DUMMY
              fi
            done
          fi
        fi
      fi

      if [ -d "$ITEM" ]; then
        # It's an directory, travel deeper
        (travel $1 $2/$ITEM)
      elif [ ! -L "$ITEM" ]; then
        # Mount this file
        mktouch $MOUNTINFO/$2/$ITEM $1
      fi
    done
  fi
}

bind_mount() {
  if [ -e "$1" -a -e "$2" ]; then
    mount -o bind $1 $2
    if [ "$?" -eq "0" ]; then 
      log_print "Mount: $1"
    else 
      log_print "Mount Fail: $1"
    fi 
  fi
}

merge_image() {
  if [ -f "$1" ]; then
    log_print "$1 found"
    if [ -f "$IMG" ]; then
      log_print "$IMG found, attempt to merge"

      # Handle large images
      target_size_check $1
      MERGEUSED=$curUsedM
      target_size_check $IMG
      if [ "$MERGEUSED" -gt "$curFreeM" ]; then
        NEWDATASIZE=$((((MERGEUSED + curUsedM) / 32 + 2) * 32))
        log_print "Expanding $IMG to ${NEWDATASIZE}M..."
        resize2fs $IMG ${NEWDATASIZE}M
      fi

      # Start merging
      mkdir /cache/data_img
      mkdir /cache/merge_img

      # setup loop devices
      loopsetup $IMG
      LOOPDATA=$LOOPDEVICE
      log_print "$LOOPDATA $IMG"

      loopsetup $1
      LOOPMERGE=$LOOPDEVICE
      log_print "$LOOPMERGE $1"

      if [ ! -z "$LOOPDATA" ]; then
        if [ ! -z "$LOOPMERGE" ]; then
          # if loop devices have been setup, mount images
          OK=true

          if [ `mount -t ext4 -o rw,noatime $LOOPDATA /cache/data_img >/dev/null 2>&1; echo $?` -ne 0 ]; then
            OK=false
          fi

          if [ `mount -t ext4 -o rw,noatime $LOOPMERGE /cache/merge_img >/dev/null 2>&1; echo $?` -ne 0 ]; then
            OK=false
          fi

          if ($OK); then
            # Merge (will reserve selinux contexts)
            cd /cache/merge_img
            for MOD in *; do
              if [ "$MOD" != "lost+found" ]; then
                log_print "Merging: $MOD"
                rm -rf /cache/data_img/$MOD
                $TOOLPATH/cp -afc $MOD /cache/data_img/
              fi
            done
            $TOOLPATH/cp -afc .core/. /cache/data_img/.core 2>/dev/null
            log_print "Merge complete"
          fi

          umount /cache/data_img
          umount /cache/merge_img
        fi
      fi

      $TOOLPATH/losetup -d $LOOPDATA
      $TOOLPATH/losetup -d $LOOPMERGE

      rmdir /cache/data_img
      rmdir /cache/merge_img
    else 
      log_print "Moving $1 to $IMG "
      mv $1 $IMG
    fi
    rm -f $1
  fi
}

case $1 in
  post-fs )
    mv $LOGFILE /cache/last_magisk.log
    touch $LOGFILE
    chmod 644 $LOGFILE

    log_print "** Magisk post-fs mode running..."

    # No more cache mods!
    # Only for multirom!

    unblock
    ;;

  post-fs-data )
    if [ `mount | grep " /data " >/dev/null 2>&1; echo $?` -ne 0 ]; then
      # /data not mounted yet, we will be called again later
      unblock
    fi

    if [ `mount | grep " /data " | grep "tmpfs" >/dev/null 2>&1; echo $?` -eq 0 ]; then
      # /data not mounted yet, we will be called again later
      unblock
    fi

    # Don't run twice
    if [ "$(getprop magisk.restart_pfsd)" != "1" ]; then

      log_print "** Magisk post-fs-data mode running..."

      # Live patch sepolicy
      /data/magisk/sepolicy-inject --live -s su

      # Cache support
      if [ -d "/cache/data_bin" ]; then
        rm -rf /data/busybox /data/magisk
        mkdir -p /data/busybox
        mv /cache/data_bin /data/magisk
        chmod -R 755 /data/busybox /data/magisk
        /data/magisk/busybox --install -s /data/busybox
        ln -s /data/magisk/busybox /data/busybox/busybox
        # Prevent issues
        rm -f /data/busybox/su /data/busybox/sh
      fi

      mv /cache/stock_boot.img /data 2>/dev/null

      chcon -R 'u:object_r:system_file:s0' /data/busybox /data/magisk

      # Image merging
      chmod 644 $IMG /cache/magisk.img /data/magisk_merge.img 2>/dev/null
      merge_image /cache/magisk.img
      merge_image /data/magisk_merge.img

      # Mount magisk.img
      [ ! -d "$MOUNTPOINT" ] && mkdir -p $MOUNTPOINT
      if [ `cat /proc/mounts | grep $MOUNTPOINT >/dev/null 2>&1; echo $?` -ne 0 ]; then
        loopsetup $IMG
        if [ ! -z "$LOOPDEVICE" ]; then
          mount -t ext4 -o rw,noatime $LOOPDEVICE $MOUNTPOINT
        fi
      fi

      if [ `cat /proc/mounts | grep $MOUNTPOINT >/dev/null 2>&1; echo $?` -ne 0 ]; then
        log_print "magisk.img mount failed, nothing to do :("
        unblock
      fi

      # Remove empty directories and remove legacy paths and previous symlink
      rm -rf $COREDIR/bin $COREDIR/dummy $COREDIR/mirror
      $TOOLPATH/find $MOUNTPOINT -type d -depth ! -path "*core*" -exec rmdir {} \; 2>/dev/null

      # Remove modules
      for MOD in $MOUNTPOINT/* ; do
        if [ -f "$MOD/remove" ]; then
          log_print "Remove module: $MOD"
          rm -rf $MOD
        fi
      done

      # Unmount, shrink, remount
      if [ `umount $MOUNTPOINT >/dev/null 2>&1; echo $?` -eq 0 ]; then
        $TOOLPATH/losetup -d $LOOPDEVICE
        target_size_check $IMG
        NEWDATASIZE=$(((curUsedM / 32 + 2) * 32))
        if [ "$curSizeM" -gt "$NEWDATASIZE" ]; then
          log_print "Shrinking $IMG to ${NEWDATASIZE}M..."
          resize2fs $IMG ${NEWDATASIZE}M
        fi
        loopsetup $IMG
        if [ ! -z "$LOOPDEVICE" ]; then
          mount -t ext4 -o rw,noatime $LOOPDEVICE $MOUNTPOINT
        fi
        if [ `cat /proc/mounts | grep $MOUNTPOINT >/dev/null 2>&1; echo $?` -ne 0 ]; then
          log_print "magisk.img mount failed, nothing to do :("
          unblock
        fi
      fi

      log_print "Preparing modules"

      mkdir -p $DUMMDIR
      mkdir -p $MIRRDIR/system

      # Travel through all mods
      for MOD in $MOUNTPOINT/* ; do
        if [ -f "$MOD/auto_mount" -a -d "$MOD/system" -a ! -f "$MOD/disable" ]; then
          (travel $MOD system)
        fi
      done

      # Proper permissions for generated items
      $TOOLPATH/find $DUMMDIR -type d -exec chmod 755 {} \;
      $TOOLPATH/find $DUMMDIR -type f -exec chmod 644 {} \;
      $TOOLPATH/find $DUMMDIR -exec chcon 'u:object_r:system_file:s0' {} \;

      # linker(64), t*box, and app_process* are required if we need to dummy mount bin folder
      if [ -f "$MOUNTINFO/dummy/system/bin" ]; then
        rm -f $DUMMDIR/system/bin/linker* $DUMMDIR/system/bin/t*box $DUMMDIR/system/bin/app_process*
        cd /system/bin
        $TOOLPATH/cp -afc linker* t*box app_process* $DUMMDIR/system/bin/
      fi

      # Remove crap folder
      rm -rf $MOUNTPOINT/lost+found
      
      # Start doing tasks
      
      # Stage 1
      log_print "Bind mount dummy system"
      $TOOLPATH/find $MOUNTINFO/dummy -type f 2>/dev/null | while read ITEM ; do
        TARGET=${ITEM#$MOUNTINFO/dummy}
        ORIG=$DUMMDIR$TARGET
        bind_mount $ORIG $TARGET
      done

      # Stage 2
      log_print "Bind mount module items"
      $TOOLPATH/find $MOUNTINFO/system -type f 2>/dev/null | while read ITEM ; do
        TARGET=${ITEM#$MOUNTINFO}
        ORIG=`cat $ITEM`$TARGET
        bind_mount $ORIG $TARGET
        rm -f $DUMMDIR${TARGET%/*}/.dummy 2>/dev/null
      done

      # Run scripts
      run_scripts post-fs-data

      # Bind hosts for Adblock apps
      [ ! -f "$COREDIR/hosts" ] && $TOOLPATH/cp -afc /system/etc/hosts $COREDIR/hosts
      log_print "Enabling systemless hosts file support"
      bind_mount $COREDIR/hosts /system/etc/hosts

      # Stage 3
      log_print "Bind mount system mirror"
      bind_mount /system $MIRRDIR/system

      # Stage 4
      log_print "Bind mount mirror items"
      # Find all empty directores and dummy files, they should be mounted by original files in /system
      TOOLPATH=/data/busybox $TOOLPATH/find $DUMMDIR -type d \
      -exec sh -c '[ -z "$($TOOLPATH/ls -A $1)" ] && echo $1' -- {} \; \
      -o \( -type f -size 0 -print \) | \
      while read ITEM ; do
        ORIG=${ITEM/dummy/mirror}
        TARGET=${ITEM#$DUMMDIR}
        bind_mount $ORIG $TARGET
      done

      # Restart post-fs-data, since data might be changed (multirom)
      setprop magisk.restart_pfsd 1

    fi
    unblock
    ;;

  service )
    # Version info
    MAGISK_VERSION_STUB
    log_print "** Magisk late_start service mode running..."
    run_scripts service

    # MagiskHide
    if [ -f "$COREDIR/magiskhide/enable" ]; then
      [ ! -f "$COREDIR/magiskhide/hidelist" ] && mktouch $COREDIR/magiskhide/hidelist
      chmod -R 755 $COREDIR/magiskhide
      # Add Safety Net preset
      $COREDIR/magiskhide/add com.google.android.gms.unstable
      log_print "** Starting Magisk Hide"
      /data/magisk/magiskhide
    fi
    ;;

esac
