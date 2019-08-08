#!/bin/sh

start-help()
{
	echo "pot start [-h] [potname]"
	echo '  -h print this help'
	echo '  -v verbose'
	echo '  -s take a snapshot before to start'
	echo '     snapshots are identified by the epoch'
	echo '     all zfs datasets under the jail dataset are considered'
	echo '  -S take a snapshot before to start'
	echo '     snapshots are identified by the epoch'
	echo '     all zfs datasets mounted in rw are considered (full)'
	echo '  potname : the jail that has to start'
}

# $1 pot name
# $2 the network interface, if created
start-cleanup()
{
	local _pname
	_pname=$1
	if [ -z "$_pname" ]; then
		return
	fi
	if [ -n "$2" ]; then
		ifconfig ${2}a destroy
	fi
	pot-cmd stop $_pname
}

# $1 pot name
_js_dep()
{
	local _pname _depPot
	_pname=$1
	_depPot="$( _get_conf_var $_pname pot.depend )"
	if [ -z "$_depPot" ]; then
		return 0 # true
	fi
	for _d in $_depPot ; do
		pot-start $_depPot
	done
	return 0 # true
}

# $1 pot name
_js_resolv()
{
	local _pname _jdir _dns
	_pname="$1"
	_jdir="${POT_FS_ROOT}/jails/$_pname"
	_dns="$(_get_conf_var $_pname pot.dns)"
	if [ -z "$_dns" ]; then
		_dns=inherit
	fi
	if [ "$_dns" = "inherit" ]; then
		if [ ! -r /etc/resolv.conf ]; then
			_error "No resolv.conf found in /etc"
			start-cleanup $_pname
			return 1 # false
		fi
		if [ -d $_jdir/m/etc ]; then
			cp /etc/resolv.conf $_jdir/m/etc
		else
			_info "No custom etc directory found, resolv.conf not loaded"
		fi
	else # resolv.conf generation
		_domain="$( _get_conf_var $_pname host.hostname | cut -f 2 -d'.' )"
		echo "# Generated by pot" > $_jdir/m/etc/resolv.conf
		echo "search $_domain" >> $_jdir/m/etc/resolv.conf
		echo "nameserver ${POT_DNS_IP}" >> $_jdir/m/etc/resolv.conf
	fi
	return 0
}

_js_create_epair()
{
	local _epair
	_epair=$(ifconfig epair create)
	if [ -z "${_epair}" ]; then
		_error "ifconfig epair failed"
		start-cleanup $_pname
		exit 1 # false
	fi
	echo ${_epair%a}
}

# $1 pot name
_js_vnet()
{
	local _pname _bridge _epair _epairb _ip
	_pname=$1
	if ! _is_vnet_up ; then
		_info "No pot bridge found! Calling vnet-start to fix the issue"
		pot-cmd vnet-start
	fi
	_bridge=$(_pot_bridge)
	_epair=${2}a
	_epairb="${2}b"
	ifconfig ${_epair} up
	ifconfig $_bridge addm ${_epair}
	_ip=$( _get_conf_var $_pname ip )
	## if norcscript - write a ad-hoc one
	if [ "$(_get_conf_var "$_pname" "pot.attr.no-rc-script")" = "YES" ]; then
		touch ${POT_FS_ROOT}/jails/$_pname/m/tmp/tinirc
		chmod a+x ${POT_FS_ROOT}/jails/$_pname/m/tmp/tinirc
		echo "ifconfig ${_epairb} inet $_ip netmask $POT_NETMASK" >> ${POT_FS_ROOT}/jails/$_pname/m/tmp/tinirc
		echo "route add default $POT_GATEWAY" >> ${POT_FS_ROOT}/jails/$_pname/m/tmp/tinirc
	else # use rc scripts
		# set the network configuration in the pot's rc.conf
		if [ -w ${POT_FS_ROOT}/jails/$_pname/m/etc/rc.conf ]; then
			sed -i '' '/ifconfig_epair/d' ${POT_FS_ROOT}/jails/$_pname/m/etc/rc.conf
		fi
		echo "ifconfig_${_epairb}=\"inet $_ip netmask $POT_NETMASK\"" >> ${POT_FS_ROOT}/jails/$_pname/m/etc/rc.conf
		sysrc -f ${POT_FS_ROOT}/jails/$_pname/m/etc/rc.conf defaultrouter="$POT_GATEWAY"
	fi
}


# $1: exclude list
_js_get_free_rnd_port()
{
	local _min _max excl_ports used_ports rdr_ports rand
	excl_ports="$1"
	_min=$( sysctl -n net.inet.ip.portrange.reservedhigh )
	_min=$(( _min + 1 ))
	_max=$( sysctl -n net.inet.ip.portrange.first )
	_max=$(( _max - 1 ))
	used_ports="$(sockstat -p ${_min}-${_max} -4l | awk '!/USER/ { n=split($6,a,":"); if ( n == 2 ) { print a[2]; }}' | sort -u)"
	anchors="$(pfctl -a pot-rdr -s Anchors)"
	for a in $anchors ; do
		new_ports="$( pfctl -a $a -s nat -P | awk '/rdr/ { n=split($0,a," "); for(i=1;i<=n;i++) { if (a[i] == "=" ) { print a[i+1];break;}}}')"
		rdr_ports="$rdr_ports $new_ports"
	done
	rand=$_min
	while [ $rand -le $_max ]; do
		for p in $excl_ports $used_ports $rdr_ports ; do
			if [ "$p" = "$rand" ]; then
				rand=$(( rand + 1 ))
				continue 2
			fi
		done
		echo $rand
		break
	done
}

# $1 pot name
_js_export_ports()
{
	local _pname _ip _ports _excl_list _pot_port _host_port
	_pname=$1
	_ip="$( _get_conf_var $_pname ip )"
	_ports="$( _get_pot_export_ports $_pname )"
	_pfrules="/tmp/pot_${_pname}_pfrules"
	if [ -z "$_ports" ]; then
		return
	fi
	rm -f $_pfrules
	for _port in $_ports ; do
		_pot_port="$( echo "${_port}" | cut -d':' -f 1)"
		_host_port="$( echo "${_port}" | cut -d':' -f 2)"
		if [ "$_pot_port" = "$_port" ]; then
			_host_port=$( _js_get_free_rnd_port "$_excl_list" )
		fi
		_debug "Redirect: from $POT_EXTIF : $_host_port to $_ip : $_port"
		echo "rdr pass on $POT_EXTIF proto tcp from any to $POT_EXTIF port $_host_port -> $_ip port $_pot_port" >> $_pfrules
		_excl_list="$_excl_list $_host_port"
	done
	pfctl -a pot-rdr/$_pname -f $_pfrules
}

# $1 jail name
_js_rss()
{
	# shellcheck disable=SC2039
	local _pname _jid _cpus _cpuset _memory
	_pname=$1
	_cpus="$( _get_conf_var "$_pname" pot.rss.cpus)"
	_memory="$( _get_conf_var "$_pname" pot.rss.memory)"
	if [ -n "$_cpus" ]; then
		_jid="$( jls -j "$_pname" | sed 1d | awk '{ print $1 }' )"
		_cpuset="$( potcpu get-cpu -n $_cpus )"
		cpuset -l $_cpuset -j $_jid
	fi
	if [ -n "$_memory" ]; then
		if ! _is_rctl_available ; then
			_info "memory constraint cannot be applies because rctl is not enabled - ignoring"
		else
			rctl -a jail:$_pname:memoryuse:deny=$_memory
		fi
	fi
}

# $1 pot name
_js_get_cmd()
{
	# shellcheck disable=SC2039
	local _pname _cdir _value
	_pname="$1"
	_cdir="${POT_FS_ROOT}/jails/$_pname/conf"
	_value="$( grep "^pot.cmd=" "$_cdir/pot.conf" | cut -f2 -d'=' )"
	[ -z "$_value" ] && _value="sh /etc/rc"
	echo "$_value"
}

_js_norc()
{
	local _pname
	_pname="$1"
	_cmd="$(_js_get_cmd $_pname)"
	echo $_cmd >> ${POT_FS_ROOT}/jails/$_pname/m/tmp/tinirc
}

_bg_start()
{
	# shellcheck disable=SC2039
	local _pname _persist _conf
	_pname=$1
	_conf="${POT_FS_ROOT}/jails/$_pname/conf/pot.conf"
	_persist="$(_get_conf_var "$_pname" "pot.attr.persistent")"
	sleep 3
	if [ "$_persist" = "NO" ]; then
		jail -m name="$_pname" nopersist
	fi
	if _is_pot_prunable "$_pname" ; then
		# set-attr cannot be used for read-only attributes
		${SED} -i '' -e "/^pot.attr.to-be-pruned=.*/d" "$_conf"
		echo "pot.attr.to-be-pruned=YES" >> "$_conf"
	fi
	_js_rss "$_pname"
}

# $1 jail name
_js_start()
{
	# shellcheck disable=SC2039
	local _pname _iface _hostname _osrelease _param _ip _cmd _persist _bgstart
	_pname="$1"
	_iface=
	_param="allow.set_hostname=false allow.raw_sockets allow.socket_af allow.sysvipc"
	_param="$_param allow.chflags exec.clean mount.devfs"
	if [ "$(_get_conf_var "$_pname" "pot.attr.procfs")" = "YES" ]; then
		_param="$_param mount.procfs"
	fi
	if [ "$(_get_conf_var "$_pname" "pot.attr.fdescfs")" = "YES" ]; then
		_param="$_param mount.fdescfs"
	fi
	_hostname="$( _get_conf_var $_pname host.hostname )"
	_osrelease="$( _get_conf_var $_pname osrelease )"
	_param="$_param name=$_pname host.hostname=$_hostname osrelease=$_osrelease"
	_param="$_param path=${POT_FS_ROOT}/jails/$_pname/m"
	_persist="$(_get_conf_var "$_pname" "pot.attr.persistent")"
	if [ "$_persist" != "NO" ]; then
		_param="$_param persist"
	fi
	_ip=$( _get_conf_var $_pname ip )
	case "$( _get_conf_var "$_pname" network_type )" in
	"inherit")
		_param="$_param ip4=inherit ip6=inherit"
		;;
	"alias")
		if potnet ip4check -H "$_ip" ; then
			_param="$_param interface=${POT_EXTIF} ip4.addr=$_ip"
		else
			_param="$_param interface=${POT_EXTIF} ip6.addr=$_ip"
		fi
		;;
	"public-bridge")
		_iface="$( _js_create_epair )"
		_js_vnet "$_pname" "$_iface"
		_param="$_param vnet vnet.interface=${_iface}b"
		_js_export_ports "$_pname"
		;;
	esac
	if [ "$(_get_conf_var "$_pname" "pot.attr.no-rc-script")" = "YES" ]; then
		_js_norc "$_pname"
		_cmd=/tmp/tinirc
	else
		_cmd="$( _js_get_cmd "$_pname" )"
	fi
	_bg_start "$_pname" &
	_info "Starting the pot $_pname"
	jail -c -J "/tmp/${_pname}.jail.conf" $_param command=$_cmd
	sleep 1
	if ! _is_pot_running "$_pname" ; then
		start-cleanup "$_pname" "${_iface}"
		if [ "$_persist" = "NO" ]; then
			return 0
		else
			return 1
		fi
	fi
}

pot-start()
{
	local _pname _snap
	_snap=none
	OPTIND=1
	while getopts "hvsS" _o ; do
		case "$_o" in
		h)
			start-help
			${EXIT} 0
			;;
		v)
			_POT_VERBOSITY=$(( _POT_VERBOSITY + 1))
			;;
		s)
			_snap=normal
			;;
		S)
			_snap=full
			;;
		*)
			start-help
			${EXIT} 1
			;;
		esac
	done
	_pname="$( eval echo \$$OPTIND)"
	if [ -z "$_pname" ]; then
		_error "A pot name is mandatory"
		start-help
		return 1
	fi
	if ! _is_pot $_pname ; then
		return 1
	fi
	if _is_pot_running $_pname ; then
		_debug "pot $_pname is already running"
		return 0
	fi
	## detect obsolete config parameter
	if [ -n "$(_get_conf_var "$_pname" "pot.export.static.ports")" ] || 
		[ -n "$(_get_conf_var "$_pname" "ip4")" ]; then
		_error "Configuration file for $_pname contains obsolete elements"
		_error "Please run pot update-config -p $_pname to fix"
		return 1
	fi
	if [ -n "$(_get_conf_var "$_pname" "pot.rss.cpuset")" ]; then
		_info "Found old cpuset rss limitation - it will be ignored"
		_info "Please run pot update-config -p $_pname to clean up the configuration"
	fi
	if ! _is_uid0 ; then
		return 1
	fi
	if _is_pot_vnet $_pname ; then
		if ! _is_vnet_available ; then
			_error "This kernel doesn't support VIMAGE! No vnet possible - abort"
			return 1
		fi
	fi

	if ! _js_dep $_pname ; then
		_error "dependecy failed to start"
	fi
	case $_snap in
		normal)
			_pot_zfs_snap $_pname
			;;
		full)
			_pot_zfs_snap_full $_pname
			;;
		none|*)
			;;
	esac
	if ! _pot_mount "$_pname" ; then
		_error "Mount failed "
		start-cleanup "$_pname"
		return 1
	fi
	_js_resolv $_pname
	if ! _js_start $_pname ; then
		_error "$_pname failed to start"
		return 1
	fi
	return 0
}
