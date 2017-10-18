#!/bin/sh

create-fscomp-help()
{
	echo "pot create-fscomp [-h] -z dataset"
	echo '  -h print this help'
	echo '  -v verbose'
	echo '  -z dataset : the dataset name (mandatory)'
}

pot-create-fscomp()
{
	local _dset
	_dset=
	args=$(getopt hz: $*)
	set -- $args
	while true; do
		case "$1" in
		-h)
			create-fscomp-help
			exit 0
			;;
		-z)
			_dset="${POT_ZFS_ROOT}/fscomp/$2"
			shift 2
			;;
		-v)
			_POT_VERBOSITY=$(( _POT_VERBOSITY + 1))
			shift
			;;
		--)
			shift
			break
			;;
		*)
			create-fscomp-help
			exit 1
		esac
	done

	if [ -z "$_dset" ]; then
		_error "zfs dataset is missing"
		create-fscomp-help
		exit 1
	fi
		
	if ! _zfs_is_dataset "$_dset" ; then
		zfs create "$_dset"
		if [ $? -ne 0 ]; then
			_error "zfs dataset $_dset failed"
			exit 1
		fi
	else
		_info "zfs dataset $_dset already exists"
	fi
}