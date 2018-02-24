#!/bin/bash

VER="1.0"

help() {
    echo "Execute:"
    echo "  $0 <image file>"
    echo
    echo "Script modifies LEDE OpenWrt images for Netgear R7800:"
    echo "  https://openwrt.org/toh/hwdata/netgear/netgear_r7800"
    echo "enabling full flash for apps."
    echo "New image file with 'fullflash' in its name will be created."
    echo
    echo "To do a flash backup see:"
    echo "  https://wiki.openwrt.org/doc/howto/generic.backup"
    echo "Note in original mtd mapping there is not needed to backup the 'firmware'"
    echo "section as it duplicates 'kernel' and 'ubi' sections."
    echo "In full flash version there is no need to backup the 'netgear' section."
    echo
    echo "First the 'factory' image must be flashed as it comes with ubi content,"
    echo "next updates can be done from 'sysypgrade' images directly via web interface."
    echo "Note: every further sysupgrade must use image with adequate flash size."
    echo
    echo "The 'factory' image can be flashed from vendor web page or via tftp recovery:"
    echo "  https://kb.netgear.com/22688/How-to-upload-firmware-to-a-NETGEAR-router-using-TFTP"
    echo "  Set host IP to 192.168.1.x as the router will be at 192.168.1.1"
    echo "  \"Turn off the power, push and hold the reset button with a pin\""
    echo "  \"Turn on the power and wait till power led starts flashing white\""
    echo "  \"(after it first flashes orange for a while)\""
    echo "  \"Release the pin and tftp the factory img in binary mode.\""
    echo "  \"The power led will stop flashing if you succeeded in transferring the image,\""
    echo "  \" and the router reboots rather quickly with the new firmware.\""
    exit
}

err() {
    echo "v.$VER $1"
    [ -n "$WORKDIR" -a -d "$WORKDIR" ] && rm -rf "$WORKDIR"
    exit
}

declare -A DTB_ORIGINAL=(
["ubi@168"]="00 00 00 9c 01 68 00 00 01 e0 00 00"
["firmware@148"]="00 00 00 9c 01 48 00 00 02 00 00 00"
)

declare -A DTB_MODIFIED=(
["ubi@168"]="00 00 00 9c 01 68 00 00 06 28 00 00"
["firmware@148"]="00 00 00 9c 01 48 00 00 06 48 00 00"
)

KERNEL_FILENAME="kernel"

# <file>
updatedtb() {
    local len=80
    local label
    local offset
    local pattern
    local modified
    local rawd
    
    for label in ${!DTB_ORIGINAL[*]}; do
	offset=$(strings -a -t d "$1" | sed -n "/${label}/s/^ *\([0-9a-f]*\) .*\$/\1/p") || err "${LINENO} $label"
	pattern=$(od "$1" -j $offset -A n -v -t x1 -N $len | tr -d "\n\r") || err "${LINENO} $label"
	modified="${pattern/${DTB_ORIGINAL[$label]}/${DTB_MODIFIED[$label]}}" || err "${LINENO} $label"
	[ "$pattern" == "$modified" ] && err "${LINENO} $label"
	rawd="$(echo "$modified" | sed 's/ /\\x/g')" || err "${LINENO} $label"
	echo -ne "$rawd" | dd of="$1" oflag=seek_bytes seek=$offset conv=notrunc || err "${LINENO} $label"
    done
}


# <from> <to>
diffsum() {
    local a=0

    for s in $1; do
	a=$(($a + 0x$s))
    done
    a=$(($a % 256))

    local b=0
    for s in $2; do
	b=$(($b + 0x$s))
    done
    b=$(($b % 256))
    
    [ $b -lt $a ] && b=$(($b + 256))

    return $(($b - $a))
}

dtbsum() {
    local a=0

    for s in ${!DTB_ORIGINAL[*]}; do
	diffsum "${DTB_ORIGINAL[$s]}" "${DTB_MODIFIED[$s]}"
	a=$(($a + $?))
    done

    return $(($a % 256))
}

# <file>
mkkernel() {
    local header_size=64
    local data_crc_offs=6
    local header_crc_offs=1
    local kernel_file="$1"
    local header_file="$WORKDIR/kheader"
    local data_file="$WORKDIR/kdata"
    local out_file="$WORKDIR/kout"
    local data_size
    local header_original
    local header_modified
    local data_crc32
    local header_crc32
    local sum

    [ -f "$kernel_file" ] || err "${LINENO}"

    data_size=$(file -b "$kernel_file" | sed -n '/(Not compressed)/s/^.*compressed), \([0-9]*\) bytes.*$/\1/p')
    [ $? -eq 0 -a -n "$data_size" ] || err "${LINENO}"

    dd if="$kernel_file" of="$header_file" bs=$header_size count=1 || err "${LINENO}"

    header_original=$(od -A n -v -t x1 "$header_file")
    [ $? -eq 0 -a -n "$header_original" ] || err "${LINENO}"

    dd if="$kernel_file" of="$data_file" iflag=skip_bytes skip=$header_size bs=$data_size count=1 || err "${LINENO}"

    updatedtb "$data_file"

    data_crc32=$(crc32 "$data_file" | cut -f 1 | sed 's/\(..\)/\\x\1/g')
    [ $? -eq 0 -a -n "$data_crc32" ] || err "${LINENO}"

    echo -ne "$data_crc32" | dd of="$header_file" bs=4 seek=$data_crc_offs conv=notrunc || err "${LINENO}"

    echo -ne "\x00\x00\x00\x00" | dd of="$header_file" bs=4 seek=$header_crc_offs conv=notrunc || err "${LINENO}"

    header_crc32=$(crc32 "$header_file" | cut -f 1 | sed 's/\(..\)/\\x\1/g')
    [ $? -eq 0 -a -n "$header_crc32" ] || err "${LINENO}"

    echo -ne "$header_crc32" | dd of="$header_file" bs=4 seek=$header_crc_offs conv=notrunc || err "${LINENO}"

    header_modified=$(od -A n -v -t x1 "$header_file")
    [ $? -eq 0 -a -n "$header_modified" ] || err "${LINENO}"

    dd if="$header_file" of="$kernel_file" conv=notrunc || err "${LINENO}"
    dd if="$data_file" of="$kernel_file" oflag=seek_bytes seek=$header_size conv=notrunc || err "${LINENO}"

    diffsum "$header_original" "$header_modified"
    return $?
}

# <infile> <insize> <outfile>
mkfactory() {
    local factory_header_size=128
    local kernel_file="$WORKDIR/kernel"
    local tmp_file="$WORKDIR/tmpfile"
    local infile="$1"
    local insize="$2"
    local outfile="$3"
    local sum_original
    local sum_kernel
    local sum_dtb
    local kernel_file

    # no need to verify sum for the file as if it is wrong it will stil be wrong after changes

    cp "$infile" "$tmp_file"
    sum_original=$(od "$tmp_file" -j $(($insize - 1)) -A n -v -t u1)
    [ $? -eq 0 -a -n "$sum_original" ] || err "${LINENO}"

    dd if="$tmp_file" of="$kernel_file" iflag=skip_bytes skip=$factory_header_size || err "${LINENO}"

    mkkernel "$kernel_file"
    sum=$?
    echo "orig:$sum_original"
    echo "kern:$sum"
    dd if="$kernel_file" of="$tmp_file" oflag=seek_bytes seek=$factory_header_size conv=notrunc || err "${LINENO}"

    dtbsum
    sum=$((($sum + $?) % 256))
    [ $sum_original -lt $sum ] && sum_original=$(($sum_original + 256))
    sum=$(($sum_original - $sum))

    sum=$(printf '%x' ${sum}) || err "${LINENO}"
    echo -ne "\x$sum" | dd of="$tmp_file" oflag=seek_bytes seek=$(($insize - 1)) || err "${LINENO}"

    mv "$tmp_file" "$outfile" || err "${LINENO}"
}

# <infile> <insize> <outfile>
mksysupgrade() {
    local tar_dir="sysupgrade-r7800"
    local kernel_file="$WORKDIR/$tar_dir/kernel"
    local tmp_file="$WORKDIR/tmpfile"
    local tr_size=16
    local tr_magic=" 46 57 78 30"
    local tr_crc_offs=4
    local infile="$1"
    local insize="$2"
    local outfile="$3"
    local magic
    local tail_size
    local embed_crc32
    local img_crc32
    local rawd

    # verify image
    magic=$(od "$infile" -j $(($insize - $tr_size)) -A n -v -t x1 -N 4)
    [ $? -eq 0 -a "$magic" == "$tr_magic" ] || err "${LINENO}"

    embed_crc32=$(od "$infile" -j $(($insize - $tr_size + $tr_crc_offs)) -A n -v -t x4 -N 4 --endian=big)
    [ $? -eq 0 -a -n "$embed_crc32" ] || err "${LINENO}"

    dd if="$infile" of="$tmp_file" bs=$(($insize - $tr_size)) count=1 || err "${LINENO}"

    img_crc32=$(crc32 "$tmp_file" | cut -f 1) || err "${LINENO}"
    [ $? -eq 0 -a -n "$img_crc32" ] || err "${LINENO}"
    img_crc32="$(printf '%x' $((0xffffffff ^ 0x$img_crc32)))" || err "${LINENO}"
    [ $? -eq 0 -a " $img_crc32" == "$embed_crc32" ] || err "${LINENO}"
    # image verified

    tar -xf "$infile" -C "$WORKDIR" || err "${LINENO}"

    mkkernel "$kernel_file"

    tar -C "$WORKDIR" -cf "$tmp_file" "$tar_dir" || err "${LINENO}"

    tail_size=$(od "$infile" -j $(($insize - 4)) -A n -v -t u4 --endian=big)
    [ $? -eq 0 -a -n "$tail_size" ] || err "${LINENO}"

    dd if="$infile" iflag=skip_bytes skip=$(($insize - $tail_size)) bs=$(($tail_size - $tr_size)) count=1 >> "$tmp_file" || err "${LINENO}"

    img_crc32=$(crc32 "$tmp_file" | cut -f 1) || err "${LINENO}"
    [ $? -eq 0 -a -n "$img_crc32" ] || err "${LINENO}"

    rawd="$(echo "$tr_magic" | sed 's/ /\\x/g')" || err "${LINENO}"
    echo -ne "$rawd" >> "$tmp_file" || err "${LINENO}"

    rawd="$(printf '%x' $((0xFFFFFFFF ^ 0x$img_crc32)) | sed 's/\(..\)/\\x\1/g')" || err "${LINENO}"
    echo -ne "$rawd"  >> "$tmp_file" || err "${LINENO}"

    dd if="$infile" iflag=skip_bytes skip=$(($insize - $tr_size + $tr_crc_offs + 4)) >> "$tmp_file" || err "${LINENO}"

    mv "$tmp_file" "$outfile" || err "${LINENO}"
}

[ $# -eq 1 ] || help

WORKDIR=$(mktemp -d) || err "${LINENO}"

fsize=$(stat -c '%s' "$1")
[ $? -eq 0 -a -n "$fsize" ] || err "${LINENO}"

ftype=$(file -b "$1")
[ $? -eq 0 -a -n "$ftype" ] || err "${LINENO}"

ofile="${1%.*}-fullflash.${1##*.}"

if [ "$ftype" == "data" ]; then #factory
    mkfactory "$1" "$fsize" "$ofile"
else #sysupgrade
    mksysupgrade "$1" "$fsize" "$ofile"
fi

[ -n "$WORKDIR" -a -d "$WORKDIR" ] && rm -rf "$WORKDIR"

echo "File $ofile created."
