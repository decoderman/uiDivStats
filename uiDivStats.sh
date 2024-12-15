#!/bin/sh

###################################################################
##                                                               ##
##           _  _____   _          _____  _          _           ##
##          (_)|  __ \ (_)        / ____|| |        | |          ##
##    _   _  _ | |  | | _ __   __| (___  | |_  __ _ | |_  ___    ##
##   | | | || || |  | || |\ \ / / \___ \ | __|/ _  || __|/ __|   ##
##   | |_| || || |__| || | \ V /  ____) || |_| (_| || |_ \__ \   ##
##    \__,_||_||_____/ |_|  \_/  |_____/  \__|\__,_| \__||___/   ##
##                                                               ##
##             https://github.com/jackyaz/uiDivStats             ##
##                                                               ##
###################################################################
# Last Modified: 2024-Dec-15
#------------------------------------------------------------------

#################        Shellcheck directives      ###############
# shellcheck disable=SC2009
# shellcheck disable=SC2012
# shellcheck disable=SC2016
# shellcheck disable=SC2018
# shellcheck disable=SC2019
# shellcheck disable=SC2059
# shellcheck disable=SC2086
# shellcheck disable=SC2155
# shellcheck disable=SC2174
# shellcheck disable=SC3018
# shellcheck disable=SC3043
# shellcheck disable=SC3045
###################################################################

### Start of script variables ###
readonly SCRIPT_NAME="uiDivStats"
readonly SCRIPT_VERSION="v4.0.5"
SCRIPT_BRANCH="master"
SCRIPT_REPO="https://raw.githubusercontent.com/decoderman/$SCRIPT_NAME/$SCRIPT_BRANCH"
readonly SCRIPT_DIR="/jffs/addons/$SCRIPT_NAME.d"
readonly SCRIPT_CONF="$SCRIPT_DIR/config"
readonly SCRIPT_USB_DIR="/opt/share/uiDivStats.d"
readonly SCRIPT_WEBPAGE_DIR="$(readlink /www/user)"
readonly SCRIPT_WEB_DIR="$SCRIPT_WEBPAGE_DIR/$SCRIPT_NAME"
readonly SHARED_DIR="/jffs/addons/shared-jy"
readonly SHARED_REPO="https://raw.githubusercontent.com/decoderman/shared-jy/master"
readonly SHARED_WEB_DIR="$SCRIPT_WEBPAGE_DIR/shared-jy"
readonly DNS_DB="$SCRIPT_USB_DIR/dnsqueries.db"
readonly CSV_OUTPUT_DIR="$SCRIPT_USB_DIR/csv"
[ -z "$(nvram get odmpid)" ] && ROUTER_MODEL="$(nvram get productid)" || ROUTER_MODEL="$(nvram get odmpid)"
SQLITE3_PATH="/opt/bin/sqlite3"
readonly DIVERSION_DIR="/opt/share/diversion"
readonly STATSEXCLUDE_LIST_FILE="$SCRIPT_DIR/statsexcludelist"

##----------------------------------------##
## Modified by Martinski W. [2024-Dec-06] ##
##----------------------------------------##
# For daily CRON job to trim database #
readonly defTrimDB_Hour=0
readonly defTrimDB_Mins=1
readonly defGenrDB_Mins=10
readonly trimLOGFileSize=65536
readonly trimLOGFilePath="${SCRIPT_USB_DIR}/uiDivStats_Trim.LOG"
readonly trimTMPOldsFile="${SCRIPT_USB_DIR}/uiDivStats_Olds.TMP"
readonly trimLogDateForm="%Y-%m-%d %H:%M:%S"

readonly oneKByte=1024
readonly oneMByte=1048576
readonly oneGByte=1073741824
readonly SHARE_TEMP_DIR="/opt/share/tmp"

### End of script variables ###

### Start of output format variables ###
readonly CRIT="\\e[41m"
readonly ERR="\\e[31m"
readonly WARN="\\e[33m"
readonly PASS="\\e[32m"
readonly BOLD="\\e[1m"
readonly SETTING="${BOLD}\\e[36m"
readonly CLEARFORMAT="\\e[0m"

##-------------------------------------##
## Added by Martinski W. [2024-Sep-22] ##
##-------------------------------------##
readonly REDct="\033[1;31m\033[1m"
readonly GRNct="\033[1;32m\033[1m"
readonly CLEARct="\033[0m"

### End of output format variables ###

##----------------------------------------##
## Modified by Martinski W. [2024-Dec-12] ##
##----------------------------------------##
# $1 = print to syslog, $2 = message to print, $3 = log level
Print_Output()
{
    local prioStr  prioNum
    if [ $# -gt 2 ] && [ -n "$3" ]
    then prioStr="$3"
    else prioStr="NOTICE"
    fi
	if [ "$1" = "true" ]
    then
		case "$prioStr" in
		    "$CRIT") prioNum=2 ;;
		     "$ERR") prioNum=3 ;;
		    "$WARN") prioNum=4 ;;
		    "$PASS") prioNum=6 ;; #INFO#
		          *) prioNum=5 ;; #NOTICE#
		esac
		logger -t "$SCRIPT_NAME" -p $prioNum "$2"
	fi
	printf "${BOLD}${3}%s${CLEARFORMAT}\n\n" "$2"
}

Validate_Number()
{
	if [ "$1" -eq "$1" ] 2>/dev/null; then
		return 0
	else
		return 1
	fi
}

Validate_IP()
{
	if expr "$1" : '[0-9][0-9]*\.[0-9][0-9]*\.[0-9][0-9]*\.[0-9][0-9]*$' >/dev/null
	then
		for i in 1 2 3 4
		do
			if [ "$(echo "$1" | cut -d. -f$i)" -gt 255 ]; then
				Print_Output false "Octet $i ($(echo "$1" | cut -d. -f$i)) - is invalid, must be less than 255" "$ERR"
				return 1
			fi
		done
	else
		Print_Output false "$1 - is not a valid IPv4 address, valid format is 1.2.3.4" "$ERR"
		return 1
	fi
}

Firmware_Version_Check()
{
	if nvram get rc_support | grep -qF "am_addons"; then
		return 0
	else
		return 1
	fi
}

### Code for these functions inspired by https://github.com/Adamm00 - credit to @Adamm ###
Check_Lock()
{
	if [ -f "/tmp/$SCRIPT_NAME.lock" ]
	then
		ageoflock="$(($(date +%s) - $(date +%s -r "/tmp/$SCRIPT_NAME.lock")))"
		if [ "$ageoflock" -gt 600 ]  #10 minutes#
		then
			Print_Output true "Stale lock file found (>600 seconds old) - purging lock" "$ERR"
			kill "$(sed -n '1p' "/tmp/$SCRIPT_NAME.lock")" >/dev/null 2>&1
			Clear_Lock
			echo "$$" > "/tmp/$SCRIPT_NAME.lock"
			return 0
		else
			Print_Output true "Lock file found (age: $ageoflock seconds) - statistic generation likely currently in progress" "$ERR"
			if [ $# -eq 0 ] || [ -z "$1" ]
			then
				exit 1
			else
				if [ "$1" = "webui" ]; then
					echo 'var uidivstatsstatus = "LOCKED";' > /tmp/detect_uidivstats.js
					exit 1
				fi
				return 1
			fi
		fi
	else
		echo "$$" > "/tmp/$SCRIPT_NAME.lock"
		return 0
	fi
}

Clear_Lock()
{
	rm -f "/tmp/$SCRIPT_NAME.lock" 2>/dev/null
	return 0
}

############################################################################

Set_Version_Custom_Settings()
{
	SETTINGSFILE="/jffs/addons/custom_settings.txt"
	case "$1" in
		local)
			if [ -f "$SETTINGSFILE" ]
			then
				if [ "$(grep -c "uidivstats_version_local" $SETTINGSFILE)" -gt 0 ]; then
					if [ "$2" != "$(grep "uidivstats_version_local" /jffs/addons/custom_settings.txt | cut -f2 -d' ')" ]; then
						sed -i "s/uidivstats_version_local.*/uidivstats_version_local $2/" "$SETTINGSFILE"
					fi
				else
					echo "uidivstats_version_local $2" >> "$SETTINGSFILE"
				fi
			else
				echo "uidivstats_version_local $2" >> "$SETTINGSFILE"
			fi
		;;
		server)
			if [ -f "$SETTINGSFILE" ]
			then
				if [ "$(grep -c "uidivstats_version_server" $SETTINGSFILE)" -gt 0 ]; then
					if [ "$2" != "$(grep "uidivstats_version_server" /jffs/addons/custom_settings.txt | cut -f2 -d' ')" ]; then
						sed -i "s/uidivstats_version_server.*/uidivstats_version_server $2/" "$SETTINGSFILE"
					fi
				else
					echo "uidivstats_version_server $2" >> "$SETTINGSFILE"
				fi
			else
				echo "uidivstats_version_server $2" >> "$SETTINGSFILE"
			fi
		;;
	esac
}

Update_Check()
{
	echo 'var updatestatus = "InProgress";' > "$SCRIPT_WEB_DIR/detect_update.js"
	doupdate="false"
	localver=$(grep "SCRIPT_VERSION=" "/jffs/scripts/$SCRIPT_NAME" | grep -m1 -oE 'v[0-9]{1,2}([.][0-9]{1,2})([.][0-9]{1,2})')
	/usr/sbin/curl -fsL --retry 3 "$SCRIPT_REPO/$SCRIPT_NAME.sh" | grep -qF "jackyaz" || { Print_Output true "404 error detected - stopping update" "$ERR"; return 1; }
	serverver=$(/usr/sbin/curl -fsL --retry 3 "$SCRIPT_REPO/$SCRIPT_NAME.sh" | grep "SCRIPT_VERSION=" | grep -m1 -oE 'v[0-9]{1,2}([.][0-9]{1,2})([.][0-9]{1,2})')
	if [ "$localver" != "$serverver" ]; then
		doupdate="version"
		Set_Version_Custom_Settings server "$serverver"
		echo 'var updatestatus = "'"$serverver"'";'  > "$SCRIPT_WEB_DIR/detect_update.js"
	else
		localmd5="$(md5sum "/jffs/scripts/$SCRIPT_NAME" | awk '{print $1}')"
		remotemd5="$(curl -fsL --retry 3 "$SCRIPT_REPO/$SCRIPT_NAME.sh" | md5sum | awk '{print $1}')"
		if [ "$localmd5" != "$remotemd5" ]; then
			doupdate="md5"
			Set_Version_Custom_Settings server "$serverver-hotfix"
			echo 'var updatestatus = "'"$serverver-hotfix"'";'  > "$SCRIPT_WEB_DIR/detect_update.js"
		fi
	fi
	if [ "$doupdate" = "false" ]; then
		echo 'var updatestatus = "None";'  > "$SCRIPT_WEB_DIR/detect_update.js"
	fi
	echo "$doupdate,$localver,$serverver"
}

Update_Version()
{
	if [ $# -eq 0 ] || [ -z "$1" ]
	then
		updatecheckresult="$(Update_Check)"
		isupdate="$(echo "$updatecheckresult" | cut -f1 -d',')"
		localver="$(echo "$updatecheckresult" | cut -f2 -d',')"
		serverver="$(echo "$updatecheckresult" | cut -f3 -d',')"

		if [ "$isupdate" = "version" ]; then
			Print_Output true "New version of $SCRIPT_NAME available - $serverver" "$PASS"
		elif [ "$isupdate" = "md5" ]; then
			Print_Output true "MD5 hash of $SCRIPT_NAME does not match - hotfix available - $serverver" "$PASS"
		fi

		if [ "$isupdate" != "false" ]
		then
			printf "\\n${BOLD}Do you want to continue with the update? (y/n)${CLEARFORMAT}  "
			read -r confirm
			case "$confirm" in
				y|Y)
					printf "\\n"
					Update_File uidivstats_www.asp
					Update_File taildns.tar.gz
					Update_File shared-jy.tar.gz

					/usr/sbin/curl -fsL --retry 3 "$SCRIPT_REPO/$SCRIPT_NAME.sh" -o "/jffs/scripts/$SCRIPT_NAME" && Print_Output true "$SCRIPT_NAME successfully updated"
					chmod 0755 "/jffs/scripts/$SCRIPT_NAME"
					Set_Version_Custom_Settings local "$serverver"
					Set_Version_Custom_Settings server "$serverver"
					Clear_Lock
					PressEnter
					exec "$0"
					exit 0
				;;
				*)
					printf "\\n"
					Clear_Lock
					return 1
				;;
			esac
		else
			Print_Output true "No updates available - latest is $localver" "$WARN"
			Clear_Lock
		fi
	fi

	if [ "$1" = "force" ]
	then
		serverver=$(/usr/sbin/curl -fsL --retry 3 "$SCRIPT_REPO/$SCRIPT_NAME.sh" | grep "SCRIPT_VERSION=" | grep -m1 -oE 'v[0-9]{1,2}([.][0-9]{1,2})([.][0-9]{1,2})')
		Print_Output true "Downloading latest version ($serverver) of $SCRIPT_NAME" "$PASS"
		Update_File uidivstats_www.asp
		Update_File taildns.tar.gz
		Update_File shared-jy.tar.gz
		/usr/sbin/curl -fsL --retry 3 "$SCRIPT_REPO/$SCRIPT_NAME.sh" -o "/jffs/scripts/$SCRIPT_NAME" && Print_Output true "$SCRIPT_NAME successfully updated" "$PASS"
		chmod 0755 "/jffs/scripts/$SCRIPT_NAME"
		Set_Version_Custom_Settings local "$serverver"
		Set_Version_Custom_Settings server "$serverver"
		Clear_Lock
		if [ -z "$2" ]; then
			PressEnter
			exec "$0"
		elif [ "$2" = "unattended" ]; then
			exec "$0" postupdate
		fi
		exit 0
	fi
}

Update_File()
{
	if [ "$1" = "uidivstats_www.asp" ]
	then
		tmpfile="/tmp/$1"
		Download_File "$SCRIPT_REPO/$1" "$tmpfile"
		if [ -f "$SCRIPT_DIR/$1" ]
		then
			if ! diff -q "$tmpfile" "$SCRIPT_DIR/$1" >/dev/null 2>&1; then
				Get_WebUI_Page "$SCRIPT_DIR/$1"
				sed -i "\\~$MyPage~d" /tmp/menuTree.js
				rm -f "$SCRIPT_WEBPAGE_DIR/$MyPage" 2>/dev/null
				Download_File "$SCRIPT_REPO/$1" "$SCRIPT_DIR/$1"
				Print_Output true "New version of $1 downloaded" "$PASS"
				Mount_WebUI
			fi
		else
			Download_File "$SCRIPT_REPO/$1" "$SCRIPT_DIR/$1"
			Print_Output true "New version of $1 downloaded" "$PASS"
			Mount_WebUI
		fi
		rm -f "$tmpfile"
	elif [ "$1" = "taildns.tar.gz" ]
	then
		if [ ! -f "$SCRIPT_DIR/${1}.md5" ]
		then
			Download_File "$SCRIPT_REPO/$1" "$SCRIPT_DIR/$1"
			Download_File "$SCRIPT_REPO/${1}.md5" "$SCRIPT_DIR/${1}.md5"
			tar -xzf "$SCRIPT_DIR/$1" -C "$SCRIPT_DIR"
			if [ -f /opt/etc/init.d/S90taildns ]; then
				/opt/etc/init.d/S90taildns stop >/dev/null 2>&1
				sleep 3
			fi
			mv "$SCRIPT_DIR/taildns.d/S90taildns" /opt/etc/init.d/S90taildns
			/opt/etc/init.d/S90taildns start >/dev/null 2>&1
			rm -f "$SCRIPT_DIR/$1"
			Print_Output true "New version of $1 downloaded" "$PASS"
		else
			localmd5="$(cat "$SCRIPT_DIR/${1}.md5")"
			remotemd5="$(curl -fsL --retry 3 "$SCRIPT_REPO/${1}.md5")"
			if [ "$localmd5" != "$remotemd5" ]
			then
				Download_File "$SCRIPT_REPO/$1" "$SCRIPT_DIR/$1"
				Download_File "$SCRIPT_REPO/${1}.md5" "$SCRIPT_DIR/${1}.md5"
				tar -xzf "$SCRIPT_DIR/$1" -C "$SCRIPT_DIR"
				if [ -f /opt/etc/init.d/S90taildns ]; then
					/opt/etc/init.d/S90taildns stop >/dev/null 2>&1
					sleep 3
				fi
				mv "$SCRIPT_DIR/taildns.d/S90taildns" /opt/etc/init.d/S90taildns
				/opt/etc/init.d/S90taildns start >/dev/null 2>&1
				rm -f "$SCRIPT_DIR/$1"
				Print_Output true "New version of $1 downloaded" "$PASS"
			fi
		fi
	elif [ "$1" = "shared-jy.tar.gz" ]
	then
		if [ ! -f "$SHARED_DIR/${1}.md5" ]
		then
			Download_File "$SHARED_REPO/$1" "$SHARED_DIR/$1"
			Download_File "$SHARED_REPO/${1}.md5" "$SHARED_DIR/${1}.md5"
			tar -xzf "$SHARED_DIR/$1" -C "$SHARED_DIR"
			rm -f "$SHARED_DIR/$1"
			Print_Output true "New version of $1 downloaded" "$PASS"
		else
			localmd5="$(cat "$SHARED_DIR/${1}.md5")"
			remotemd5="$(curl -fsL --retry 3 "$SHARED_REPO/${1}.md5")"
			if [ "$localmd5" != "$remotemd5" ]
			then
				Download_File "$SHARED_REPO/$1" "$SHARED_DIR/$1"
				Download_File "$SHARED_REPO/${1}.md5" "$SHARED_DIR/${1}.md5"
				tar -xzf "$SHARED_DIR/$1" -C "$SHARED_DIR"
				rm -f "$SHARED_DIR/$1"
				Print_Output true "New version of $1 downloaded" "$PASS"
			fi
		fi
	else
		return 1
	fi
}

Conf_FromSettings()
{
	SETTINGSFILE="/jffs/addons/custom_settings.txt"
	TMPFILE="/tmp/uidivstats_settings.txt"

	if [ -f "$SETTINGSFILE" ]
	then
		if [ "$(grep "uidivstats_" $SETTINGSFILE | grep -v "version" -c)" -gt 0 ]
		then
			Print_Output true "Updated settings from WebUI found, merging into $SCRIPT_CONF" "$PASS"
			cp -a "$SCRIPT_CONF" "${SCRIPT_CONF}.bak"
			grep "uidivstats_" "$SETTINGSFILE" | grep -v "version" > "$TMPFILE"
			sed -i "s/uidivstats_//g;s/ /=/g" "$TMPFILE"
			while IFS='' read -r line || [ -n "$line" ]
			do
				SETTINGNAME="$(echo "$line" | cut -f1 -d'=' | awk '{ print toupper($1) }')"
				SETTINGVALUE="$(echo "$line" | cut -f2 -d'=')"
				if [ "$SETTINGNAME" = "DOMAINSTOEXCLUDE" ]
				then
					echo "$SETTINGVALUE" | sed 's~||||~\n~g' > "$STATSEXCLUDE_LIST_FILE"
					awk 'NF' "$STATSEXCLUDE_LIST_FILE" > "$STATSEXCLUDE_LIST_FILE.tmp"
					mv "$STATSEXCLUDE_LIST_FILE.tmp" "$STATSEXCLUDE_LIST_FILE"
				else
					sed -i "s/$SETTINGNAME=.*/$SETTINGNAME=$SETTINGVALUE/" "$SCRIPT_CONF"
				fi
			done < "$TMPFILE"
			grep 'uidivstats_version' "$SETTINGSFILE" > "$TMPFILE"
			sed -i "\\~uidivstats_~d" "$SETTINGSFILE"
			mv "$SETTINGSFILE" "${SETTINGSFILE}.bak"
			cat "${SETTINGSFILE}.bak" "$TMPFILE" > "$SETTINGSFILE"
			rm -f "$TMPFILE"
			rm -f "${SETTINGSFILE}.bak"

			QueryMode "$(QueryMode check)"
			sleep 3
			CacheMode "$(CacheMode check)"

			Print_Output true "Merge of updated settings from WebUI completed successfully" "$PASS"
		else
			Print_Output false "No updated settings from WebUI found, no merge into $SCRIPT_CONF necessary" "$PASS"
		fi
	fi
}

##----------------------------------------##
## Modified by Martinski W. [2024-Dec-06] ##
##----------------------------------------##
Create_Dirs()
{
	if [ ! -d "$SCRIPT_DIR" ]; then
		mkdir -p "$SCRIPT_DIR"
	fi

	if [ ! -d "$SHARED_DIR" ]; then
		mkdir -p "$SHARED_DIR"
	fi

	if [ ! -d "$SCRIPT_WEBPAGE_DIR" ]; then
		mkdir -p "$SCRIPT_WEBPAGE_DIR"
	fi

	if [ ! -d "$SCRIPT_WEB_DIR" ]; then
		mkdir -p "$SCRIPT_WEB_DIR"
	fi

	if [ ! -d "$CSV_OUTPUT_DIR" ]; then
		mkdir -p "$CSV_OUTPUT_DIR"
	fi

	if [ ! -f "$STATSEXCLUDE_LIST_FILE" ]; then
		touch "$STATSEXCLUDE_LIST_FILE"
	fi

	if [ ! -d "$SHARE_TEMP_DIR" ]
	then
		mkdir -m 777 -p "$SHARE_TEMP_DIR"
		export SQLITE_TMPDIR TMPDIR
	fi
}

Create_Symlinks()
{
	rm -rf "${SCRIPT_WEB_DIR:?}/"* 2>/dev/null

	ln -s /tmp/detect_uidivstats.js "$SCRIPT_WEB_DIR/detect_uidivstats.js" 2>/dev/null
	ln -s "$SCRIPT_USB_DIR/SQLData.js" "$SCRIPT_WEB_DIR/SQLData.js" 2>/dev/null
	ln -s "$SCRIPT_CONF" "$SCRIPT_WEB_DIR/config.htm" 2>/dev/null
	ln -s "$STATSEXCLUDE_LIST_FILE" "$SCRIPT_WEB_DIR/domainstoexclude.htm"

	if [ ! -f /opt/bin/find ] && [ -f /opt/bin/opkg ]
	then
		opkg update
		opkg install findutils
	fi

	UpdateDiversionWeeklyStatsFile 2>/dev/null

	ln -s "$CSV_OUTPUT_DIR" "$SCRIPT_WEB_DIR/csv" 2>/dev/null

	if [ ! -d "$SHARED_WEB_DIR" ]; then
		ln -s "$SHARED_DIR" "$SHARED_WEB_DIR" 2>/dev/null
	fi
}

##----------------------------------------##
## Modified by Martinski W. [2024-Dec-02] ##
##----------------------------------------##
Conf_Exists()
{
	if [ -f "$SCRIPT_CONF" ]
	then
		dos2unix "$SCRIPT_CONF"
		chmod 0644 "$SCRIPT_CONF"
		sed -i -e 's/"//g' "$SCRIPT_CONF"

		if ! grep -q "^DAYSTOKEEP=" "$SCRIPT_CONF"; then
			echo "DAYSTOKEEP=30" >> "$SCRIPT_CONF"
		fi
		if ! grep -q "^TRIMDB_HOUR=" "$SCRIPT_CONF"; then
			echo "TRIMDB_HOUR=$defTrimDB_Hour" >> "$SCRIPT_CONF"
		fi
		if grep -q "^TRIMDB_MINS=" "$SCRIPT_CONF"; then
			sed -i "/^TRIMDB_MINS=/d" "$SCRIPT_CONF"
		fi
		if ! grep -q "^LASTXQUERIES=" "$SCRIPT_CONF"; then
			echo "LASTXQUERIES=5000" >> "$SCRIPT_CONF"
		fi
		if ! grep -q "^CACHEMODE=" "$SCRIPT_CONF"; then
			echo "CACHEMODE=tmp" >> "$SCRIPT_CONF"
		fi
		if ! grep -q "^QUERYMODE=" "$SCRIPT_CONF"; then
			echo "QUERYMODE=all" >> "$SCRIPT_CONF"
		fi
		if ! grep -q "^BACKG_STATS_PROCS_ENABLED=" "$SCRIPT_CONF"; then
			echo "BACKG_STATS_PROCS_ENABLED=true" >> "$SCRIPT_CONF"
		fi
		sed -i -e 's/^QUERYMODE=A+AAAA$/QUERYMODE=A+AAAA+HTTPS/g' "$SCRIPT_CONF"
		return 0
	else
		{ echo "QUERYMODE=all"; echo "CACHEMODE=tmp"
		  echo "DAYSTOKEEP=30"; echo "LASTXQUERIES=5000"
		  echo "TRIMDB_HOUR=$defTrimDB_Hour"
		  echo "BACKG_STATS_PROCS_ENABLED=true"
		} > "$SCRIPT_CONF"
		return 1
	fi
}

##----------------------------------------##
## Modified by Martinski W. [2024-Dec-02] ##
##----------------------------------------##
Auto_ServiceEvent()
{
	case $1 in
		create)
			if [ -f /jffs/scripts/service-event ]
			then
				STARTUPLINECOUNT="$(grep -c '# '"$SCRIPT_NAME" /jffs/scripts/service-event)"
				STARTUPLINECOUNTEX="$(grep -cx 'if echo "$2" | /bin/grep -q "'"$SCRIPT_NAME"'"; then { /jffs/scripts/'"$SCRIPT_NAME"' service_event "$@" & }; fi # '"$SCRIPT_NAME" /jffs/scripts/service-event)"

				if [ "$STARTUPLINECOUNT" -gt 1 ] || { [ "$STARTUPLINECOUNTEX" -eq 0 ] && [ "$STARTUPLINECOUNT" -gt 0 ]; }
				then
					sed -i -e '/# '"$SCRIPT_NAME"'/d' /jffs/scripts/service-event
					STARTUPLINECOUNT=0
				fi
				if [ "$STARTUPLINECOUNTEX" -eq 0 ]
				then
					{
					  echo 'if echo "$2" | /bin/grep -q "'"$SCRIPT_NAME"'"; then { /jffs/scripts/'"$SCRIPT_NAME"' service_event "$@" & }; fi # '"$SCRIPT_NAME"
					} >> /jffs/scripts/service-event
				fi
			else
				{
				  echo "#!/bin/sh" ; echo
				  echo 'if echo "$2" | /bin/grep -q "'"$SCRIPT_NAME"'"; then { /jffs/scripts/'"$SCRIPT_NAME"' service_event "$@" & }; fi # '"$SCRIPT_NAME"
				  echo
				} > /jffs/scripts/service-event
				chmod 0755 /jffs/scripts/service-event
			fi
		;;
		delete)
			if [ -f /jffs/scripts/service-event ]
			then
				STARTUPLINECOUNT=$(grep -c '# '"$SCRIPT_NAME" /jffs/scripts/service-event)

				if [ "$STARTUPLINECOUNT" -gt 0 ]; then
					sed -i -e '/# '"$SCRIPT_NAME"'/d' /jffs/scripts/service-event
				fi
			fi
		;;
	esac
}

##----------------------------------------##
## Modified by Martinski W. [2024-Dec-02] ##
##----------------------------------------##
Auto_Startup()
{
	case $1 in
		create)
			if [ -f /jffs/scripts/services-start ]
			then
				STARTUPLINECOUNT="$(grep -c '# '"$SCRIPT_NAME" /jffs/scripts/services-start)"

				if [ "$STARTUPLINECOUNT" -gt 0 ]; then
					sed -i -e '/# '"$SCRIPT_NAME"'/d' /jffs/scripts/services-start
				fi
			fi
			if [ -f /jffs/scripts/post-mount ]
			then
				STARTUPLINECOUNT="$(grep -c '# '"$SCRIPT_NAME" /jffs/scripts/post-mount)"
				STARTUPLINECOUNTEX="$(grep -cx '\[ -x "${1}/entware/bin/opkg" \] && \[ -x /jffs/scripts/'"$SCRIPT_NAME"' \] && /jffs/scripts/'"$SCRIPT_NAME"' startup "$@" & # '"$SCRIPT_NAME" /jffs/scripts/post-mount)"

				if [ "$STARTUPLINECOUNT" -gt 1 ] || { [ "$STARTUPLINECOUNTEX" -eq 0 ] && [ "$STARTUPLINECOUNT" -gt 0 ]; }
				then
					sed -i -e '/# '"$SCRIPT_NAME"'/d' /jffs/scripts/post-mount
					STARTUPLINECOUNT=0
				fi
				if [ "$STARTUPLINECOUNTEX" -eq 0 ]
				then
					{
					  echo '[ -x "${1}/entware/bin/opkg" ] && [ -x /jffs/scripts/'"$SCRIPT_NAME"' ] && /jffs/scripts/'"$SCRIPT_NAME"' startup "$@" & # '"$SCRIPT_NAME"
					} >> /jffs/scripts/post-mount
				fi
			else
				{
				  echo "#!/bin/sh" ; echo
				  echo '[ -x "${1}/entware/bin/opkg" ] && [ -x /jffs/scripts/'"$SCRIPT_NAME"' ] && /jffs/scripts/'"$SCRIPT_NAME"' startup "$@" & # '"$SCRIPT_NAME"
				  echo
				} > /jffs/scripts/post-mount
				chmod 0755 /jffs/scripts/post-mount
			fi
		;;
		delete)
			if [ -f /jffs/scripts/services-start ]
			then
				STARTUPLINECOUNT=$(grep -c '# '"$SCRIPT_NAME" /jffs/scripts/services-start)

				if [ "$STARTUPLINECOUNT" -gt 0 ]; then
					sed -i -e '/# '"$SCRIPT_NAME"'/d' /jffs/scripts/services-start
				fi
			fi
			if [ -f /jffs/scripts/post-mount ]
			then
				STARTUPLINECOUNT=$(grep -c '# '"$SCRIPT_NAME" /jffs/scripts/post-mount)

				if [ "$STARTUPLINECOUNT" -gt 0 ]; then
					sed -i -e '/# '"$SCRIPT_NAME"'/d' /jffs/scripts/post-mount
				fi
			fi
		;;
	esac
}


##----------------------------------------##
## Modified by Martinski W. [2024-Nov-01] ##
##----------------------------------------##
Auto_Cron()
{
	case $1 in
		create)
			STARTUPLINECOUNTGENERATE="$(cru l | grep -c "${SCRIPT_NAME}_generate")"
			STARTUPLINECOUNTTRIM="$(cru l | grep -c "${SCRIPT_NAME}_trim")"
			STARTUPLINECOUNTQUERYLOG="$(cru l | grep -c "${SCRIPT_NAME}_querylog")"
			STARTUPLINECOUNTFLUSHTODB="$(cru l | grep -c "${SCRIPT_NAME}_flushtodb")"

			STARTUPLINECOUNTEXGENERATE="$(cru l | grep "${SCRIPT_NAME}_generate" | grep -c "^$defGenrDB_Mins [*] ")"
			if [ "$STARTUPLINECOUNTGENERATE" -ne 0 ] && [ "$STARTUPLINECOUNTEXGENERATE" -eq 0 ]
			then
				cru d "${SCRIPT_NAME}_generate"
				STARTUPLINECOUNTGENERATE="$(cru l | grep -c "${SCRIPT_NAME}_generate")"
			fi

			STARTUPLINECOUNTEXTRIM="$(cru l | grep "${SCRIPT_NAME}_trim" | grep -c "^$defTrimDB_Mins ")"
			if [ "$STARTUPLINECOUNTTRIM" -ne 0 ] && [ "$STARTUPLINECOUNTEXTRIM" -eq 0 ]
			then
				cru d "${SCRIPT_NAME}_trim"
				STARTUPLINECOUNTTRIM="$(cru l | grep -c "${SCRIPT_NAME}_trim")"
			fi

			STARTUPLINECOUNTEXQUERYLOG="$(cru l | grep "${SCRIPT_NAME}_querylog" | grep -c '^[*]/2 [*] ')"
			if [ "$STARTUPLINECOUNTQUERYLOG" -ne 0 ] && [ "$STARTUPLINECOUNTEXQUERYLOG" -eq 0 ]
			then
				cru d "${SCRIPT_NAME}_querylog"
				STARTUPLINECOUNTQUERYLOG="$(cru l | grep -c "${SCRIPT_NAME}_querylog")"
			fi

			STARTUPLINECOUNTEXFLUSHTODB="$(cru l | grep "${SCRIPT_NAME}_flushtodb" | grep -c '^4-59/5 [*] ')"
			if [ "$STARTUPLINECOUNTFLUSHTODB" -ne 0 ] && [ "$STARTUPLINECOUNTEXFLUSHTODB" -eq 0 ]
			then
				cru d "${SCRIPT_NAME}_flushtodb"
				STARTUPLINECOUNTFLUSHTODB="$(cru l | grep -c "${SCRIPT_NAME}_flushtodb")"
			fi

			if [ "$STARTUPLINECOUNTGENERATE" -eq 0 ]; then
				cru a "${SCRIPT_NAME}_generate" "$defGenrDB_Mins * * * * /jffs/scripts/$SCRIPT_NAME generate"
			fi
			if [ "$STARTUPLINECOUNTTRIM" -eq 0 ]; then
				cru a "${SCRIPT_NAME}_trim" "$defTrimDB_Mins $(_TrimDatabaseTime_ hour) * * * /jffs/scripts/$SCRIPT_NAME trimdb"
			fi
			if [ "$STARTUPLINECOUNTQUERYLOG" -eq 0 ]; then
				cru a "${SCRIPT_NAME}_querylog" "*/2 * * * * /jffs/scripts/$SCRIPT_NAME querylog"
			fi
			if [ "$STARTUPLINECOUNTFLUSHTODB" -eq 0 ]; then
				cru a "${SCRIPT_NAME}_flushtodb" "4-59/5 * * * * /jffs/scripts/$SCRIPT_NAME flushtodb"
			fi
		;;
		delete)
			STARTUPLINECOUNTGENERATE=$(cru l | grep -c "${SCRIPT_NAME}_generate")
			STARTUPLINECOUNTTRIM=$(cru l | grep -c "${SCRIPT_NAME}_trim")
			STARTUPLINECOUNTQUERYLOG=$(cru l | grep -c "${SCRIPT_NAME}_querylog")
			STARTUPLINECOUNTFLUSHTODB=$(cru l | grep -c "${SCRIPT_NAME}_flushtodb")

			if [ "$STARTUPLINECOUNTGENERATE" -gt 0 ]; then
				cru d "${SCRIPT_NAME}_generate"
			fi
			if [ "$STARTUPLINECOUNTTRIM" -gt 0 ]; then
				cru d "${SCRIPT_NAME}_trim"
			fi
			if [ "$STARTUPLINECOUNTQUERYLOG" -gt 0 ]; then
				cru d "${SCRIPT_NAME}_querylog"
			fi
			if [ "$STARTUPLINECOUNTFLUSHTODB" -gt 0 ]; then
				cru d "${SCRIPT_NAME}_flushtodb"
			fi
		;;
	esac
}

Auto_DNSMASQ_Postconf(){
	case $1 in
		create)
			if [ -f /jffs/scripts/dnsmasq.postconf ]; then
				STARTUPLINECOUNT=$(grep -c '# '"$SCRIPT_NAME" /jffs/scripts/dnsmasq.postconf)
				STARTUPLINECOUNTEX=$(grep -cx "/jffs/scripts/$SCRIPT_NAME dnsmasq & # $SCRIPT_NAME" /jffs/scripts/dnsmasq.postconf)

				if [ "$STARTUPLINECOUNT" -gt 1 ] || { [ "$STARTUPLINECOUNTEX" -eq 0 ] && [ "$STARTUPLINECOUNT" -gt 0 ]; }; then
					sed -i -e '/# '"$SCRIPT_NAME"'/d' /jffs/scripts/dnsmasq.postconf
				fi

				if [ "$STARTUPLINECOUNTEX" -eq 0 ]; then
					echo "/jffs/scripts/$SCRIPT_NAME dnsmasq & # $SCRIPT_NAME" >> /jffs/scripts/dnsmasq.postconf
				fi
			else
				echo "#!/bin/sh" > /jffs/scripts/dnsmasq.postconf
				echo "" >> /jffs/scripts/dnsmasq.postconf
				echo "/jffs/scripts/$SCRIPT_NAME dnsmasq & # $SCRIPT_NAME" >> /jffs/scripts/dnsmasq.postconf
				chmod 0755 /jffs/scripts/dnsmasq.postconf
			fi
		;;
		delete)
			if [ -f /jffs/scripts/dnsmasq.postconf ]; then
				STARTUPLINECOUNT=$(grep -c '# '"$SCRIPT_NAME" /jffs/scripts/dnsmasq.postconf)

				if [ "$STARTUPLINECOUNT" -gt 0 ]; then
					sed -i -e '/# '"$SCRIPT_NAME"'/d' /jffs/scripts/dnsmasq.postconf
				fi
			fi
		;;
	esac
}

Download_File(){
	/usr/sbin/curl -fsL --retry 3 "$1" -o "$2"
}

Get_WebUI_Page(){
	MyPage="none"
	for i in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do
		page="/www/user/user$i.asp"
		if [ -f "$page" ] && [ "$(md5sum < "$1")" = "$(md5sum < "$page")" ]; then
			MyPage="user$i.asp"
			return
		elif [ "$MyPage" = "none" ] && [ ! -f "$page" ]; then
			MyPage="user$i.asp"
		fi
	done
}

### function based on @dave14305's FlexQoS webconfigpage function ###
Get_WebUI_URL()
{
	urlpage=""
	urlproto=""
	urldomain=""
	urlport=""

	urlpage="$(sed -nE "/$SCRIPT_NAME/ s/.*url\: \"(user[0-9]+\.asp)\".*/\1/p" /tmp/menuTree.js)"
	if [ "$(nvram get http_enable)" -eq 1 ]; then
		urlproto="https"
	else
		urlproto="http"
	fi
	if [ -n "$(nvram get lan_domain)" ]; then
		urldomain="$(nvram get lan_hostname).$(nvram get lan_domain)"
	else
		urldomain="$(nvram get lan_ipaddr)"
	fi
	if [ "$(nvram get ${urlproto}_lanport)" -eq 80 ] || [ "$(nvram get ${urlproto}_lanport)" -eq 443 ]; then
		urlport=""
	else
		urlport=":$(nvram get ${urlproto}_lanport)"
	fi

	if echo "$urlpage" | grep -qE "user[0-9]+\.asp"; then
		echo "${urlproto}://${urldomain}${urlport}/${urlpage}" | tr "A-Z" "a-z"
	else
		echo "WebUI page not found"
	fi
}
### ###

Mount_WebUI()
{
	Print_Output true "Mounting WebUI tab for $SCRIPT_NAME" "$PASS"
	LOCKFILE=/tmp/addonwebui.lock
	FD=386
	eval exec "$FD>$LOCKFILE"
	flock -x "$FD"
	Get_WebUI_Page "$SCRIPT_DIR/uidivstats_www.asp"
	if [ "$MyPage" = "none" ]; then
		Print_Output true "Unable to mount $SCRIPT_NAME WebUI page, exiting" "$CRIT"
		Clear_Lock
		exit 1
	fi
	cp -f "$SCRIPT_DIR/uidivstats_www.asp" "$SCRIPT_WEBPAGE_DIR/$MyPage"
	echo "$SCRIPT_NAME" > "$SCRIPT_WEBPAGE_DIR/$(echo $MyPage | cut -f1 -d'.').title"

	if [ "$(uname -o)" = "ASUSWRT-Merlin" ]
	then
		if [ ! -f /tmp/menuTree.js ]; then
			cp -f /www/require/modules/menuTree.js /tmp/
		fi

		sed -i "\\~$MyPage~d" /tmp/menuTree.js

		if /bin/grep 'tabName: \"Diversion\"},' /tmp/menuTree.js >/dev/null 2>&1; then
			sed -i "/tabName: \"Diversion\"/a {url: \"$MyPage\", tabName: \"$SCRIPT_NAME\"}," /tmp/menuTree.js
		else
			sed -i "/url: \"Advanced_SwitchCtrl_Content.asp\", tabName:/a {url: \"$MyPage\", tabName: \"$SCRIPT_NAME\"}," /tmp/menuTree.js
		fi

		umount /www/require/modules/menuTree.js 2>/dev/null
		mount -o bind /tmp/menuTree.js /www/require/modules/menuTree.js
	fi
	flock -u "$FD"
	Print_Output true "Mounted $SCRIPT_NAME WebUI page as $MyPage" "$PASS"
}

##-------------------------------------##
## Added by Martinski W. [2024-Dec-13] ##
##-------------------------------------##
_ToggleBackgroundProcsEnabled_()
{
    local paramStr=""
    [ $# -eq 1 ] && [ -n "$1" ] && paramStr="$1"

    if [ "$paramStr" = "check" ]
    then
        dbBackgProcsEnabled="$(grep "^BACKG_STATS_PROCS_ENABLED=" "$SCRIPT_CONF" | cut -f2 -d"=")"
        echo "${dbBackgProcsEnabled:=true}"
        return 0
    fi
    dbBackgProcsEnabled="$(_ToggleBackgroundProcsEnabled_ check)"

    if [ "$paramStr" = "enable" ] && [ "$dbBackgProcsEnabled" = "true" ]
    then
        printf "\nBackground processing is already ${GRNct}ENABLED${CLEARct}.\n\n"
        return 0
    fi
    if [ "$paramStr" = "disable" ] && [ "$dbBackgProcsEnabled" = "false" ]
    then
        printf "\nBackground processing is already ${REDct}DISABLED${CLEARct}.\n\n"
        return 0
    fi
    if [ "$dbBackgProcsEnabled" = "true" ]
    then
        printf "${REDct}**-WARNING-**${CLEARct}${BOLD}${WARN}\n"
        printf "This option disables the background processing of statistics\n"
        printf "generated from the domain ad-blocking performed by Diversion.\n"
        printf "While in a DISABLED state, the script can be executed but in a\n"
        printf "very constrained mode and with extremely limited functionality.\n"
        printf "Make sure to re-enable background processing as soon as you can.${CLEARct}\n"
        if _WaitForYESorNO_ "\nProceed to ${REDct}DISABLE${CLEARct}?"
        then
            dbBackgProcsEnabled=false
            printf "Disabling background processing...\n"
            sed -i 's/^BACKG_STATS_PROCS_ENABLED.*$/BACKG_STATS_PROCS_ENABLED=false/' "$SCRIPT_CONF"
            /opt/etc/init.d/S90taildns stop >/dev/null 2>&1
            sleep 3
            Auto_Cron delete 2>/dev/null
            printf "Background processing is now ${REDct}DISABLED${CLEARct}.\n\n"
            _UpdateBackgroundProcsState_
            return 0
        else
            printf "Background processing remains ${GRNct}ENABLED${CLEARct}.\n\n"
            return 1
        fi
    fi
    if [ "$dbBackgProcsEnabled" = "false" ]
    then
        dbBackgProcsEnabled=true
        printf "Enabling background processing...\n"
        sed -i 's/^BACKG_STATS_PROCS_ENABLED.*$/BACKG_STATS_PROCS_ENABLED=true/' "$SCRIPT_CONF"
        Auto_Cron create 2>/dev/null
        /opt/etc/init.d/S90taildns start >/dev/null 2>&1
        sleep 2
        printf "Background processing is now ${GRNct}ENABLED${CLEARct}.\n\n"
        _UpdateBackgroundProcsState_
        return 0
    fi
}

##----------------------------------------##
## Modified by Martinski W. [2024-Dec-14] ##
##----------------------------------------##
QueryMode()
{
	case "$1" in
		all)
			printf "Please wait..."
			sed -i 's/^QUERYMODE.*$/QUERYMODE=all/' "$SCRIPT_CONF"
			/opt/etc/init.d/S90taildns stop >/dev/null 2>&1
			sleep 3
			"$dbBackgProcsEnabled" && \
			/opt/etc/init.d/S90taildns start >/dev/null 2>&1
		;;
		A+AAAA+HTTPS)
			printf "Please wait..."
			sed -i 's/^QUERYMODE.*$/QUERYMODE=A+AAAA+HTTPS/' "$SCRIPT_CONF"
			/opt/etc/init.d/S90taildns stop >/dev/null 2>&1
			sleep 3
			"$dbBackgProcsEnabled" && \
			/opt/etc/init.d/S90taildns start >/dev/null 2>&1
		;;
		check)
			QUERYMODE="$(grep "^QUERYMODE=" "$SCRIPT_CONF" | cut -f2 -d"=")"
			echo "${QUERYMODE:=all}"
		;;
	esac
}

##----------------------------------------##
## Modified by Martinski W. [2024-Dec-14] ##
##----------------------------------------##
CacheMode()
{
	case "$1" in
		none)
			printf "Please wait..."
			sed -i 's/^CACHEMODE.*$/CACHEMODE=none/' "$SCRIPT_CONF"
			/opt/etc/init.d/S90taildns stop >/dev/null 2>&1
			sleep 3
			Flush_Cache_To_DB
			"$dbBackgProcsEnabled" && \
			/opt/etc/init.d/S90taildns start >/dev/null 2>&1
		;;
		tmp)
			printf "Please wait..."
			sed -i 's/^CACHEMODE.*$/CACHEMODE=tmp/' "$SCRIPT_CONF"
			/opt/etc/init.d/S90taildns stop >/dev/null 2>&1
			sleep 3
			"$dbBackgProcsEnabled" && \
			/opt/etc/init.d/S90taildns start >/dev/null 2>&1
		;;
		check)
			CACHEMODE="$(grep "^CACHEMODE=" "$SCRIPT_CONF" | cut -f2 -d"=")"
			echo "${CACHEMODE:=tmp}"
		;;
	esac
}

##----------------------------------------##
## Modified by Martinski W. [2024-Oct-13] ##
##----------------------------------------##
DaysToKeep()
{
	case "$1" in
		update)
			daysToKeep="$(DaysToKeep check)"
			exitLoop=false
			while true
			do
				ScriptHeader
				printf "${BOLD}Current number of days to keep data: ${GRNct}${daysToKeep}${CLEARct}\n"
				printf "\n${BOLD}Please enter the maximum number of days\nto keep data for [1-365] (e=Exit):${CLEARFORMAT}  "
				read -r daystokeep_choice
				if [ -z "$daystokeep_choice" ] && \
				   echo "$daysToKeep" | grep -qE "^([1-9][0-9]{0,2})$" && \
				   [ "$daysToKeep" -gt 0 ] && [ "$daysToKeep" -le 365 ]
				then
					exitLoop=true
					break
				elif [ "$daystokeep_choice" = "e" ]
				then
					exitLoop=true
					break
				elif ! Validate_Number "$daystokeep_choice"
				then
					printf "\n${ERR}Please enter a valid number [1-365].${CLEARFORMAT}\n"
					PressEnter
				elif [ "$daystokeep_choice" -lt 1 ] || [ "$daystokeep_choice" -gt 365 ]
				then
					printf "\n${ERR}Please enter a number between 1 and 365.${CLEARFORMAT}\n"
					PressEnter
				else
					daysToKeep="$daystokeep_choice"
					break
				fi
			done

			if "$exitLoop"
			then
				echo ; return 1
			else
				DAYSTOKEEP="$daysToKeep"
				sed -i 's/^DAYSTOKEEP.*$/DAYSTOKEEP='"$DAYSTOKEEP"'/' "$SCRIPT_CONF"
				echo ; return 0
			fi
		;;
		check)
			DAYSTOKEEP="$(grep "^DAYSTOKEEP=" "$SCRIPT_CONF" | cut -f2 -d"=")"
			echo "${DAYSTOKEEP:=30}"
		;;
	esac
}

##----------------------------------------##
## Modified by Martinski W. [2024-Oct-13] ##
##----------------------------------------##
LastXQueries()
{
	case "$1" in
		update)
			lastXQueries="$(LastXQueries check)"
			exitLoop=false
			ScriptHeader
			while true
			do
				ScriptHeader
				printf "${BOLD}Current number of queries to display: ${GRNct}${lastXQueries}${CLEARct}\n"
				printf "\n${BOLD}Please enter the maximum number of queries\nto display in the WebUI [10-10000] (e=Exit):${CLEARFORMAT}  "
				read -r lastx_choice
				if [ -z "$lastx_choice" ] && \
				   echo "$lastXQueries" | grep -qE "^([1-9][0-9]{1,4})$" && \
				   [ "$lastXQueries" -ge 10 ] && [ "$lastXQueries" -le 10000 ]
				then
					exitLoop=true
					break
				elif [ "$lastx_choice" = "e" ]
				then
					exitLoop=true
					break
				elif ! Validate_Number "$lastx_choice"
				then
					printf "\n${ERR}Please enter a valid number [10-10000].${CLEARFORMAT}\n"
					PressEnter
				elif [ "$lastx_choice" -lt 10 ] || [ "$lastx_choice" -gt 10000 ]
				then
					printf "\n${ERR}Please enter a number between 10 and 10000.${CLEARFORMAT}\n"
					PressEnter
				else
					lastXQueries="$lastx_choice"
					break
				fi
			done

			if "$exitLoop"
			then
				echo ; return 1
			else
				LASTXQUERIES="$lastXQueries"
				sed -i 's/^LASTXQUERIES.*$/LASTXQUERIES='"$LASTXQUERIES"'/' "$SCRIPT_CONF"
				Generate_Query_Log
				echo ; return 0
			fi
		;;
		check)
			LASTXQUERIES="$(grep "^LASTXQUERIES=" "$SCRIPT_CONF" | cut -f2 -d"=")"
			echo "${LASTXQUERIES:=5000}"
		;;
	esac
}

##-------------------------------------##
## Added by Martinski W. [2024-Oct-30] ##
##-------------------------------------##
_GetFileSize_()
{
   local sizeUnits  sizeInfo  fileSize
   if [ $# -eq 0 ] || [ -z "$1" ] || [ ! -s "$1" ]
   then echo 0; return 1 ; fi

   if [ $# -lt 2 ] || [ -z "$2" ] || \
      ! echo "$2" | grep -qE "^(B|KB|MB|GB|HR|HRx)$"
   then sizeUnits="B" ; else sizeUnits="$2" ; fi

   _GetNum_() { printf "%.1f" "$(echo "$1" | awk "{print $1}")" ; }

   case "$sizeUnits" in
       B|KB|MB|GB)
           fileSize="$(ls -1l "$1" | awk -F ' ' '{print $3}')"
           case "$sizeUnits" in
               KB) fileSize="$(_GetNum_ "($fileSize / $oneKByte)")" ;;
               MB) fileSize="$(_GetNum_ "($fileSize / $oneMByte)")" ;;
               GB) fileSize="$(_GetNum_ "($fileSize / $oneGByte)")" ;;
           esac
           echo "$fileSize"
           ;;
       HR|HRx)
           fileSize="$(ls -1lh "$1" | awk -F ' ' '{print $3}')"
           sizeInfo="${fileSize}B"
           if [ "$sizeUnits" = "HR" ]
           then echo "$sizeInfo" ; return 0 ; fi
           sizeUnits="$(echo "$sizeInfo" | tr -d '.0-9')"
           case "$sizeUnits" in
               MB) fileSize="$(_GetFileSize_ "$1" KB)"
                   sizeInfo="$sizeInfo [${fileSize}KB]"
                   ;;
               GB) fileSize="$(_GetFileSize_ "$1" MB)"
                   sizeInfo="$sizeInfo [${fileSize}MB]"
                   ;;
           esac
           echo "$sizeInfo"
           ;;
       *) echo 0 ;;
   esac
   return 0
}

##-------------------------------------##
## Added by Martinski W. [2024-Dec-13] ##
##-------------------------------------##
_Get_TMPFS_Space_()
{
   local typex  total  usedx  freex
   local sizeUnits  sizeType  sizeInfo  sizeNum
   local tmpfsUsageStr  percentNum  percentStr

   if [ $# -lt 1 ] || [ -z "$1" ] || \
      ! echo "$1" | grep -qE "^(ALL|USED|FREE)$"
   then sizeType="ALL" ; else sizeType="$1" ; fi

   if [ $# -lt 2 ] || [ -z "$2" ] || \
      ! echo "$2" | grep -qE "^(KB|KBP|MBP|GBP|HR|HRx)$"
   then sizeUnits="KB" ; else sizeUnits="$2" ; fi

   _GetNum_() { printf "%.1f" "$(echo "$1" | awk "{print $1}")" ; }

   tmpfsUsageStr="$(df -kT | grep -E '^tmpfs .* /tmp$')"
   if [ -z "$tmpfsUsageStr" ]
   then echo "**ERROR**: TMPFS is *NOT* found." ; return 1
   fi
   typex="$(echo "$tmpfsUsageStr" | awk -F ' ' '{print $2}')"
   total="$(echo "$tmpfsUsageStr" | awk -F ' ' '{print $3}')"
   usedx="$(echo "$tmpfsUsageStr" | awk -F ' ' '{print $4}')"
   freex="$(echo "$tmpfsUsageStr" | awk -F ' ' '{print $5}')"

   if [ "$sizeType" = "ALL" ] ; then echo "$total" ; return 0 ; fi

   case "$sizeUnits" in
       KB|KBP|MBP|GBP)
           case "$sizeType" in
               USED) sizeNum="$usedx"
                     percentNum="$(printf "%.1f" "$(_GetNum_ "($usedx * 100 / $total)")")"
                     percentStr="[${percentNum}%]"
                     ;;
               FREE) sizeNum="$freex"
                     percentNum="$(printf "%.1f" "$(_GetNum_ "($freex * 100 / $total)")")"
                     percentStr="[${percentNum}%]"
                     ;;
           esac
           case "$sizeUnits" in
                KB) sizeInfo="$sizeNum"
                    ;;
               KBP) sizeInfo="${sizeNum}.0KB $percentStr"
                    ;;
               MBP) sizeNum="$(_GetNum_ "($sizeNum / $oneKByte)")"
                    sizeInfo="${sizeNum}MB $percentStr"
                    ;;
               GBP) sizeNum="$(_GetNum_ "($sizeNum / $oneMByte)")"
                    sizeInfo="${sizeNum}GB $percentStr"
                    ;;
           esac
           echo "$sizeInfo"
           ;;
       HR|HRx)
           tmpfsUsageStr="$(df -hT | grep -E '^tmpfs .* /tmp$')"
           case "$sizeType" in
               USED) usedx="$(echo "$tmpfsUsageStr" | awk -F ' ' '{print $4}')"
                     sizeInfo="${usedx}B"
                     ;;
               FREE) freex="$(echo "$tmpfsUsageStr" | awk -F ' ' '{print $5}')"
                     sizeInfo="${freex}B"
                     ;;
           esac
           if [ "$sizeUnits" = "HR" ]
           then echo "$sizeInfo" ; return 0 ; fi
           sizeUnits="$(echo "$sizeInfo" | tr -d '.0-9')"
           case "$sizeUnits" in
               KB) sizeInfo="$(_Get_TMPFS_Space_ "$sizeType" KBP)" ;;
               MB) sizeInfo="$(_Get_TMPFS_Space_ "$sizeType" MBP)" ;;
               GB) sizeInfo="$(_Get_TMPFS_Space_ "$sizeType" GBP)" ;;
           esac
           echo "$sizeInfo"
           ;;
       *) echo 0 ;;
   esac
   return 0
}

##-------------------------------------##
## Added by Martinski W. [2024-Dec-14] ##
##-------------------------------------##
_GetAvailableRAM_()
{
   local theMemTotal  theMemFree1  theMemAvail
   local theMemCache  theMemBuffr  theMemAvailHR
   local theMemInfoStr  percentNum  memInfoType

   _GetNum_() { printf "%.1f" "$(echo "$1" | awk "{print $1}")" ; }

   if [ $# -lt 1 ] || [ -z "$1" ] || \
      ! echo "$1" | grep -qE "^(HR|HRx)$"
   then memInfoType="HR" ; else memInfoType="$1" ; fi

   theMemInfoStr="$(head -n 8 /proc/meminfo)"
   theMemTotal="$(echo "$theMemInfoStr" | awk -F ' ' '/^MemTotal:/{print $2}')"
   theMemFree1="$(echo "$theMemInfoStr" | awk -F ' ' '/^MemFree:/{print $2}')"
   theMemAvail="$(echo "$theMemInfoStr" | awk -F ' ' '/^MemAvailable:/{print $2}')"
   if [ -z "$theMemAvail" ]
   then
       theMemCache="$(echo "$theMemInfoStr" | awk -F ' ' '/^Cached:/{print $2}')"
       theMemBuffr="$(echo "$theMemInfoStr" | awk -F ' ' '/^Buffers:/{print $2}')"
       theMemAvail="$((theMemFree1 + theMemCache + theMemBuffr))"
   fi

   if [ "$theMemAvail" -ge "$oneMByte" ]
   then theMemAvailHR="$(_GetNum_ "($theMemAvail / $oneMByte)")GB"
   elif [ "$theMemAvail" -ge "$oneKByte" ]
   then theMemAvailHR="$(_GetNum_ "($theMemAvail / $oneKByte)")MB"
   else theMemAvailHR="${theMemAvail}.0KB"
   fi
   if [ "$memInfoType" = "HRx" ]
   then
       percentNum="$(_GetNum_ "($theMemAvail * 100 / $theMemTotal)")"
       theMemAvailHR="${theMemAvailHR} [${percentNum}%]"
   fi
   echo "${theMemAvailHR}"
}

##-------------------------------------##
## Added by Martinski W. [2024-Dec-14] ##
##-------------------------------------##
_UpdateRAM_FreeSpaceInfo_()
{
   local ramFreeSpace
   local outJSfile="$SCRIPT_USB_DIR/SQLData.js"

   ramFreeSpace="$(_GetAvailableRAM_ HRx)"
   if [ ! -s "$outJSfile" ] || \
      ! grep -q "^var ramAvailableSpace =.*" "$outJSfile"
   then
       sed -i "1 i var ramAvailableSpace = '${ramFreeSpace}';" "$outJSfile"
   else
       sed -i "s/^var ramAvailableSpace =.*/var ramAvailableSpace = '${ramFreeSpace}';/" "$outJSfile"
   fi
}

##-------------------------------------##
## Added by Martinski W. [2024-Dec-13] ##
##-------------------------------------##
_UpdateTMPFS_FreeSpaceInfo_()
{
   local tmpfsFreeSpace
   local outJSfile="$SCRIPT_USB_DIR/SQLData.js"

   tmpfsFreeSpace="$(_Get_TMPFS_Space_ FREE HR)"
   if [ ! -s "$outJSfile" ] || \
      ! grep -q "^var tmpfsAvailableSpace =.*" "$outJSfile"
   then
       sed -i "2 i var tmpfsAvailableSpace = '${tmpfsFreeSpace}';" "$outJSfile"
   else
       sed -i "s/^var tmpfsAvailableSpace =.*/var tmpfsAvailableSpace = '${tmpfsFreeSpace}';/" "$outJSfile"
   fi
}

##-------------------------------------##
## Added by Martinski W. [2024-Dec-13] ##
##-------------------------------------##
_UpdateBackgroundProcsState_()
{
   local statusBackProcsState
   local outJSfile="$SCRIPT_USB_DIR/SQLData.js"

   if "$(_ToggleBackgroundProcsEnabled_ check)"
   then statusBackProcsState="ENABLED"
   else statusBackProcsState="DISABLED"
   fi
   if [ ! -s "$outJSfile" ] || \
      ! grep -q "^var backgroundProcsState =.*" "$outJSfile"
   then
       sed -i "3 i var backgroundProcsState = '${statusBackProcsState}';" "$outJSfile"
   else
       sed -i "s/^var backgroundProcsState =.*/var backgroundProcsState = '${statusBackProcsState}';/" "$outJSfile"
   fi
}

##-------------------------------------##
## Added by Martinski W. [2024-Dec-14] ##
##-------------------------------------##
_UpdateDatabaseFileSizeInfo_()
{
   local databaseFileSize
   local outJSfile="$SCRIPT_USB_DIR/SQLData.js"

   databaseFileSize="$(_GetFileSize_ "$DNS_DB" HRx)"
   if [ ! -s "$outJSfile" ] || \
      ! grep -q "^var sqlDatabaseFileSize =.*" "$outJSfile"
   then
       sed -i "1 i var sqlDatabaseFileSize = '${databaseFileSize}';" "$outJSfile"
   else
       WritePlainData_ToJS "$outJSfile" "sqlDatabaseFileSize,'${databaseFileSize}'"
   fi
   _UpdateRAM_FreeSpaceInfo_
   _UpdateTMPFS_FreeSpaceInfo_
   _UpdateBackgroundProcsState_
}

##-------------------------------------##
## Added by Martinski W. [2024-Oct-13] ##
##-------------------------------------##
_ValidateCronJobHour_()
{
   if [ $# -eq 0 ] || [ -z "$1" ] ; then return 1 ; fi
   if echo "$1" | grep -qE "^(0|[1-9][0-9]?)$" && \
      [ "$1" -ge 0 ] && [ "$1" -lt 24 ]
   then return 0 ; else return 1 ; fi
}

_ValidateCronJobMins_()
{
    if [ $# -eq 0 ] || [ -z "$1" ] ; then return 1 ; fi
    if echo "$1" | grep -qE "^(0|[1-9][0-9]?)$" && \
       [ "$1" -ge 0 ] && [ "$1" -lt 60 ]
    then return 0 ; else return 1 ; fi
}

##----------------------------------------##
## Modified by Martinski W. [2024-Dec-06] ##
##----------------------------------------##
#----------------------------------------------------------
# NOTE: The cron job MINUTES should *NOT* be modified
# because job must be scheduled to avoid conflicts with
# other cron jobs that generate/access database records.
#----------------------------------------------------------
_TrimDatabaseTime_()
{
   case "$1" in
       update)
           trimDBtimeHRx="$(_TrimDatabaseTime_ timeHRx)"
           trimDBhour="$(_TrimDatabaseTime_ hour)"
           TRIMDB_HOUR="$trimDBhour"
           exitLoop=false
           while true
           do
               ScriptHeader
               printf "${BOLD}Current schedule: ${GRNct}Daily at ${trimDBtimeHRx}${CLEARct}\n"
               printf "\n${BOLD}Enter schedule HOUR [0-23] (e=Exit):${CLEARFORMAT}  "
               read -r newTrimDBhour
               if [ -z "$newTrimDBhour" ] && _ValidateCronJobHour_ "$trimDBhour"
               then
                   exitLoop=true
                   break
               elif [ "$newTrimDBhour" = "e" ]
               then
                   exitLoop=true
                   break
               elif ! _ValidateCronJobHour_ "$newTrimDBhour"
               then
                   printf "\n${ERR}Please enter a valid hour [0-23].${CLEARFORMAT}\n"
                   PressEnter
                   continue
               else
                   trimDBhour="$newTrimDBhour"
                   break
               fi
           done

           if "$exitLoop"
           then
               echo ; return 1
           else
               if [ "$trimDBhour" -ne "$TRIMDB_HOUR" ]
               then
                   TRIMDB_HOUR="$trimDBhour"
                   sed -i 's/^TRIMDB_HOUR.*$/TRIMDB_HOUR='"$TRIMDB_HOUR"'/' "$SCRIPT_CONF"
                   cru a "${SCRIPT_NAME}_trim" "$defTrimDB_Mins $TRIMDB_HOUR * * * /jffs/scripts/$SCRIPT_NAME trimdb"
               fi
               echo ; return 0
           fi
           ;;
       hour)
           TRIMDB_HOUR="$(grep "^TRIMDB_HOUR=" "$SCRIPT_CONF" | cut -f2 -d"=")"
           echo "${TRIMDB_HOUR:=$defTrimDB_Hour}"
           ;;
       timeHRx)
           trimDBhour="$(_TrimDatabaseTime_ hour)"
           trimDBtime12hr="$(_TrimDatabaseTime_ time12hr)"
           if [ "$trimDBhour" -gt 0 ] && [ "$trimDBhour" -lt 13 ]
           then echo "$trimDBtime12hr"
           else echo "$(_TrimDatabaseTime_ time24hr) [$trimDBtime12hr]"
           fi
           ;;
       time24hr)
           printf "%02d:%02d" "$(_TrimDatabaseTime_ hour)" "$defTrimDB_Mins"
           ;;
       time12hr)
           ampmTag="AM"
           trimDBhour="$(_TrimDatabaseTime_ hour)"
           if [ "$trimDBhour" -eq 0 ]
           then trimDBhour=12
           elif [ "$trimDBhour" -eq 12 ]
           then ampmTag="PM"
           elif [ "$trimDBhour" -gt 12 ]
           then trimDBhour="$((trimDBhour - 12))" ; ampmTag="PM"
           fi
           printf "%02d:%02d $ampmTag" "$trimDBhour" "$defTrimDB_Mins"
           ;;
   esac
}

##----------------------------------------##
## Modified by Martinski W. [2024-Nov-01] ##
##----------------------------------------##
UpdateDiversionWeeklyStatsFile()
{
	rm -f "$SCRIPT_WEB_DIR/DiversionStats.htm" 2>/dev/null
	diversionstatsfile="$(/opt/bin/find "${DIVERSION_DIR}/stats" -name "Diversion_Stats*" -printf "%C@ %p\n"| sort | tail -n 1 | cut -f2 -d' ')"
    [ -n "$diversionstatsfile" ] && [ -f "$diversionstatsfile" ] && \
	ln -s "$diversionstatsfile" "$SCRIPT_WEB_DIR/DiversionStats.htm" 2>/dev/null
}

##----------------------------------------##
## Modified by Martinski W. [2024-Nov-15] ##
##----------------------------------------##
WriteStats_ToJS()
{
	if [ $# -lt 4 ] ; then return 1 ; fi

	if [ -f "$2" ]
	then
	    sed -i -e '/}/d;/function/d;/document.getElementById/d;' "$2"
	    awk 'NF' "$2" > "${2}.tmp"
	    mv -f "${2}.tmp" "$2"
	fi
	printf "\nfunction %s(){\n" "$3" >> "$2"
	html='document.getElementById("'"$4"'").innerHTML="'

	while IFS='' read -r line || [ -n "$line" ]
	do html="${html}${line}"
	done < "$1"
	html="$html"'"'
	printf "%s\n}\n" "$html" >> "$2"
}

##----------------------------------------##
## Modified by Martinski W. [2024-Oct-30] ##
##----------------------------------------##
WritePlainData_ToJS()
{
	outputfile="$1"
	shift
	for var in "$@"
	do
		varname="$(echo "$var" | cut -f1 -d',')"
		varvalue="$(echo "$var" | cut -f2 -d',')"
		if [ -f "$outputfile" ] && \
		   grep -q "^var $varname =" "$outputfile"
		then
		    sed -i "s/^var $varname =.*/var $varname = ${varvalue};/" "$outputfile"
		else
		    echo "var $varname = ${varvalue};" >> "$outputfile"
		fi
	done
}

##----------------------------------------##
## Modified by Martinski W. [2024-Dec-13] ##
##----------------------------------------##
Table_Indexes()
{
	case "$1" in
		create)
			{
			  echo "PRAGMA temp_store=1;"
			  echo "PRAGMA cache_size=-20000;"
			  echo "CREATE INDEX IF NOT EXISTS idx_clients ON dnsqueries (SrcIP);"
			} > /tmp/uidivstats-upgrade.sql
			_ApplyDatabaseSQLCmds_ /tmp/uidivstats-upgrade.sql

			{
			  echo "PRAGMA temp_store=1;"
			  echo "PRAGMA cache_size=-20000;"
			  echo "CREATE INDEX IF NOT EXISTS idx_time_clients ON dnsqueries (Timestamp,SrcIP);"
			} > /tmp/uidivstats-upgrade.sql
			_ApplyDatabaseSQLCmds_ /tmp/uidivstats-upgrade.sql

			{
			  echo "PRAGMA temp_store=1;"
			  echo "PRAGMA cache_size=-20000;"
			  echo "CREATE INDEX IF NOT EXISTS idx_allowed_time_clients ON dnsqueries (Allowed,Timestamp,SrcIP);"
			} > /tmp/uidivstats-upgrade.sql
			_ApplyDatabaseSQLCmds_ /tmp/uidivstats-upgrade.sql

			{
			  echo "PRAGMA temp_store=1;"
			  echo "PRAGMA cache_size=-20000;"
			  echo "CREATE INDEX IF NOT EXISTS idx_clients_time_domains ON dnsqueries (SrcIP,Timestamp,ReqDmn);"
			} > /tmp/uidivstats-upgrade.sql
			_ApplyDatabaseSQLCmds_ /tmp/uidivstats-upgrade.sql

			{
			  echo "PRAGMA temp_store=1;"
			  echo "PRAGMA cache_size=-20000;"
			  echo "CREATE INDEX IF NOT EXISTS idx_clients_allowed_time_domains ON dnsqueries (SrcIP,Allowed,Timestamp,ReqDmn);"
			} > /tmp/uidivstats-upgrade.sql
			_ApplyDatabaseSQLCmds_ /tmp/uidivstats-upgrade.sql

			{
			  echo "PRAGMA temp_store=1;"
			  echo "PRAGMA cache_size=-20000;"
			  echo "CREATE INDEX IF NOT EXISTS idx_time_domains ON dnsqueries (Timestamp,ReqDmn);"
			} > /tmp/uidivstats-upgrade.sql
			_ApplyDatabaseSQLCmds_ /tmp/uidivstats-upgrade.sql

			{
			  echo "PRAGMA temp_store=1;"
			  echo "PRAGMA cache_size=-20000;"
			  echo "CREATE INDEX IF NOT EXISTS idx_allowed_time_domains ON dnsqueries (Allowed,Timestamp,ReqDmn);"
			} > /tmp/uidivstats-upgrade.sql
			_ApplyDatabaseSQLCmds_ /tmp/uidivstats-upgrade.sql

			{
			  echo "PRAGMA temp_store=1;"
			  echo "PRAGMA cache_size=-20000;"
			  echo "CREATE INDEX IF NOT EXISTS idx_allowed_time ON dnsqueries (Allowed,Timestamp);"
			} > /tmp/uidivstats-upgrade.sql
			_ApplyDatabaseSQLCmds_ /tmp/uidivstats-upgrade.sql

			{
			  echo "PRAGMA temp_store=1;"
			  echo "PRAGMA cache_size=-20000;"
			  echo "CREATE INDEX IF NOT EXISTS idx_time_allowed ON dnsqueries (Timestamp,Allowed);"
			} > /tmp/uidivstats-upgrade.sql
			_ApplyDatabaseSQLCmds_ /tmp/uidivstats-upgrade.sql
		;;
		drop)
			true;
		;;
	esac
}

##----------------------------------------##
## Modified by Martinski W. [2024-Dec-13] ##
##----------------------------------------##
# $1 create/drop $2 tablename $3 frequency (hours) $4 outputfrequency
TempTime_Table()
{
	case "$1" in
		create)
			multiplier="$(echo "$3" | awk '{printf (60*60*$1)}')"
			{
				echo ".headers off"
				echo ".output /tmp/timesmin"
				echo "PRAGMA temp_store=1;"
				echo "SELECT CAST(MIN([Timestamp])/$multiplier AS INT)*$multiplier FROM ${2}${4};"
				echo ".headers off"
				echo ".output /tmp/timesmax"
				echo "SELECT CAST(MAX([Timestamp])/$multiplier AS INT)*$multiplier FROM ${2}${4};"
			} > /tmp/uidivstats.sql
			_ApplyDatabaseSQLCmds_ /tmp/uidivstats.sql

			timesmin="$(cat /tmp/timesmin)"
			timesmax="$(cat /tmp/timesmax)"
			rm -f /tmp/timesmin
			rm -f /tmp/timesmax

			if ! Validate_Number "$timesmin"; then timesmin=0; fi
			if ! Validate_Number "$timesmax"; then timesmax=0; fi

			{
				echo "PRAGMA temp_store=1;"
				echo "CREATE TABLE IF NOT EXISTS temp_timerange_$4 AS"
				echo "WITH RECURSIVE c(x) AS("
				echo "VALUES($timesmin)"
				echo "UNION ALL"
				echo "SELECT x+$multiplier FROM c WHERE x<$timesmax"
				echo ") SELECT x FROM c;"
			} > /tmp/uidivstats.sql
			_ApplyDatabaseSQLCmds_ /tmp/uidivstats.sql
			rm -f /tmp/uidivstats.sql
			;;
		drop)
			echo "DROP TABLE IF EXISTS temp_timerange_$2;" > /tmp/uidivstats.sql
			_ApplyDatabaseSQLCmds_ /tmp/uidivstats.sql
			rm -f /tmp/uidivstats.sql
		;;
	esac
}

##----------------------------------------##
## Modified by Martinski W. [2024-Oct-26] ##
##----------------------------------------##
Write_View_Sql_ToFile()
{
	if [ "$1" = "create" ]
	then
		timenow="$6"
		{
		  echo "PRAGMA temp_store=1;"
		  echo "CREATE VIEW IF NOT EXISTS ${2}${3} AS SELECT * FROM $2 WHERE ([Timestamp] >= strftime('%s',datetime($timenow,'unixepoch','-$4 day'))) AND ([Timestamp] <= $timenow);"
		} > "$5"
	elif [ "$1" = "drop" ]
	then
		{
		  echo "PRAGMA temp_store=1;"
		  echo "DROP VIEW IF EXISTS ${2}${3};"
		} > "$4"
	fi
}

##----------------------------------------##
## Modified by Martinski W. [2024-Oct-26] ##
##----------------------------------------##
#$1 fieldname $2 tablename $3 length (days) $4 outputfile $5 outputfrequency $6 sqlfile
Write_Count_Sql_ToFile()
{
	{
		echo ".mode csv"
		echo ".headers on"
		echo ".output ${4}${5}.htm"
		echo "PRAGMA temp_store=1;"
	} > "$6"

	wherestring=""
	while IFS='' read -r line || [ -n "$line" ]
	do
		if [ -n "$line" ]; then
			domain="$(echo "$line" | sed 's/\*/%/g')"
			wherestring="$wherestring AND [ReqDmn] NOT LIKE '$domain'"
		fi
	done < "$STATSEXCLUDE_LIST_FILE"

	if [ "$1" = "Total" ]; then
		wherestring="$(echo "$wherestring" | sed 's/AND/WHERE/')"
	fi

	if [ "$1" = "Total" ]; then
		echo "SELECT '$1' Fieldname,[ReqDmn] ReqDmn,Count([ReqDmn]) Count FROM ${2}${5} $wherestring GROUP BY [ReqDmn] ORDER BY COUNT([ReqDmn]) DESC LIMIT 20;" >> "$6"
	elif [ "$1" = "Blocked" ]; then
		echo "SELECT '$1' Fieldname,[ReqDmn] ReqDmn,Count([ReqDmn]) Count FROM ${2}${5} WHERE NOT [Allowed] $wherestring GROUP BY [ReqDmn] ORDER BY COUNT([ReqDmn]) DESC LIMIT 20;" >> "$6"
	fi
}

##----------------------------------------##
## Modified by Martinski W. [2024-Oct-26] ##
##----------------------------------------##
#$1 fieldname $2 tablename $3 length (days) $4 outputfile $5 outputfrequency $6 sqlfile
Write_Count_PerClient_Sql_ToFile()
{
	{
		echo ".mode csv"
		echo ".headers off"
		echo ".output ${4}${5}clients.htm"
		echo "PRAGMA temp_store=1;"
	} > "$6"

	wherestring=""
	while IFS='' read -r line || [ -n "$line" ]
	do
		if [ -n "$line" ]; then
			domain="$(echo "$line" | sed 's/\*/%/g')"
			wherestring="$wherestring AND [ReqDmn] NOT LIKE '$domain'"
		fi
	done < "$STATSEXCLUDE_LIST_FILE"

	if [ "$1" = "Total" ]
	then
		{
		  echo "SELECT '$1' Fieldname,SrcIP,ReqDmn,Count FROM"
		  echo "(SELECT [SrcIP] SrcIP,[ReqDmn] ReqDmn,Count([ReqDmn]) Count,ROW_NUMBER() OVER (PARTITION BY [SrcIP] ORDER BY Count(*) DESC) rn"
		  echo "FROM ${2}${5} WHERE [SrcIP] IN (SELECT DISTINCT [SrcIP] SrcIP FROM ${2}${5}) $wherestring"
		  echo "GROUP BY [SrcIP],[ReqDmn]) WHERE rn <=20 ORDER BY SrcIP,Count DESC;"
		} >> "$6"
	elif [ "$1" = "Blocked" ]
	then
		{
		  echo "SELECT '$1' Fieldname,SrcIP,ReqDmn,Count FROM"
		  echo "(SELECT [SrcIP] SrcIP,[ReqDmn] ReqDmn,Count([ReqDmn]) Count,ROW_NUMBER() OVER (PARTITION BY [SrcIP] ORDER BY Count(*) DESC) rn"
		  echo "FROM ${2}${5} WHERE [SrcIP] IN (SELECT DISTINCT [SrcIP] SrcIP FROM ${2}${5}) AND NOT [Allowed] $wherestring"
		  echo "GROUP BY [SrcIP],[ReqDmn]) WHERE rn <=20 ORDER BY SrcIP,Count DESC;"
		} >> "$6"
	fi
}

##----------------------------------------##
## Modified by Martinski W. [2024-Oct-26] ##
##----------------------------------------##
#$1 fieldname $2 tablename $3 frequency (hours) $4 length (days) $5 outputfile $6 outputfrequency $7 sqlfile
Write_Time_Sql_ToFile()
{
	multiplier="$(echo "$3" | awk '{printf (60*60*$1)}')"

	{
		echo ".mode csv"
		echo ".headers off"
		echo ".output ${5}${6}time.htm"
		echo "PRAGMA temp_store=1;"
	} > "$7"

	if [ "$1" = "Total" ]
	then
		echo "SELECT '$1' Fieldname,series.x Time,IFNULL(data.QueryCount2,0) QueryCount FROM (SELECT x FROM temp_timerange_$6) series LEFT JOIN (SELECT '$1' Fieldname,CAST([Timestamp]/$multiplier AS INT)*$multiplier Time2,COUNT([QueryID]) QueryCount2 FROM ${2}${6} GROUP BY Time2) data on series.x = data.Time2;" >> "$7"
	elif [ "$1" = "Blocked" ]
	then
		echo "SELECT '$1' Fieldname,series.x Time,IFNULL(data.QueryCount2,0) QueryCount FROM (SELECT x FROM temp_timerange_$6) series LEFT JOIN (SELECT '$1' Fieldname,CAST([Timestamp]/$multiplier AS INT)*$multiplier Time2,COUNT([QueryID]) QueryCount2 FROM ${2}${6} WHERE NOT [Allowed] GROUP BY Time2) data on series.x = data.Time2;" >> "$7"
	fi
}

##----------------------------------------##
## Modified by Martinski W. [2024-Oct-26] ##
##----------------------------------------##
Write_KeyStats_Sql_ToFile()
{
	{
		echo ".headers off"
		echo ".output /tmp/queries${1}${3}"
		echo "PRAGMA temp_store=1;"
	} > "$4"

	if [ "$1" = "Total" ]
	then
		echo "SELECT COUNT([QueryID]) QueryCount FROM ${2}${3};" >> "$4"
	elif [ "$1" = "Blocked" ]
	then
		echo "SELECT COUNT([QueryID]) QueryCount FROM ${2}${3} WHERE NOT [Allowed];" >> "$4"
	fi
}

##----------------------------------------##
## Modified by Martinski W. [2024-Dec-13] ##
##----------------------------------------##
Generate_NG()
{
	local foundError  foundLocked  resultStr

	TZ="$(cat /etc/TZ)"
	export TZ

	timenow="$(date +'%s')"
	timenowfriendly="$(date +'%c')"

	rm -f /tmp/uidivstats.sql
	{
		echo "PRAGMA temp_store=1;"
		echo "PRAGMA cache_size=-20000;"
		echo "BEGIN TRANSACTION;"
		echo "DELETE FROM [dnsqueries] WHERE [Timestamp] > $timenow;"
		echo "DELETE FROM [dnsqueries] WHERE [SrcIP] = 'from';"
		echo "END TRANSACTION;"
	} > /tmp/uidivstats.sql

	_ApplyDatabaseSQLCmds_ /tmp/uidivstats.sql
	rm -f /tmp/uidivstats.sql

	if [ $# -gt 0 ] && [ -n "$1" ] && [ "$1" = "fullrefresh" ]
	then
		Write_View_Sql_ToFile drop dnsqueries daily /tmp/uidivstats.sql
		_ApplyDatabaseSQLCmds_ /tmp/uidivstats.sql

		Write_View_Sql_ToFile drop dnsqueries weekly /tmp/uidivstats.sql
		_ApplyDatabaseSQLCmds_ /tmp/uidivstats.sql

		Write_View_Sql_ToFile drop dnsqueries monthly /tmp/uidivstats.sql
		_ApplyDatabaseSQLCmds_ /tmp/uidivstats.sql
		rm -f /tmp/uidivstats.sql
	fi

	Write_View_Sql_ToFile create dnsqueries daily 1 /tmp/uidivstats.sql "$timenow"
	_ApplyDatabaseSQLCmds_ /tmp/uidivstats.sql

	Write_View_Sql_ToFile create dnsqueries weekly 7 /tmp/uidivstats.sql "$timenow"
	_ApplyDatabaseSQLCmds_ /tmp/uidivstats.sql

	Write_View_Sql_ToFile create dnsqueries monthly 30 /tmp/uidivstats.sql "$timenow"
	_ApplyDatabaseSQLCmds_ /tmp/uidivstats.sql
	rm -f /tmp/uidivstats.sql

	TempTime_Table create dnsqueries 0.25 daily
	if [ $# -gt 0 ] && [ -n "$1" ] && [ "$1" = "fullrefresh" ]
	then
		TempTime_Table create dnsqueries 1 weekly
		TempTime_Table create dnsqueries 3 monthly
	fi

	Generate_Count_Blocklist_Domains

	if [ $# -gt 0 ] && [ -n "$1" ] && [ "$1" = "fullrefresh" ]
	then
		Generate_KeyStats "$timenow" fullrefresh
		Generate_Stats_From_SQLite "$timenow" fullrefresh
	else
		Generate_KeyStats "$timenow"
		Generate_Stats_From_SQLite "$timenow"
	fi

	TempTime_Table drop daily
	if [ $# -gt 0 ] && [ -n "$1" ] && [ "$1" = "fullrefresh" ]
	then
		TempTime_Table drop weekly
		TempTime_Table drop monthly
	fi

	_UpdateDatabaseFileSizeInfo_

	echo "Stats last updated: $timenowfriendly" > /tmp/uidivstatstitle.txt
	WriteStats_ToJS /tmp/uidivstatstitle.txt "$SCRIPT_USB_DIR/SQLData.js" SetuiDivStatsTitle statstitle
	echo 'var uidivstatsstatus = "Done";' > /tmp/detect_uidivstats.js
	Print_Output true "Stats updated successfully" "$PASS"
	rm -f /tmpuidivstatstitle.txt
}

##----------------------------------------##
## Modified by Martinski W. [2024-Dec-13] ##
##----------------------------------------##
Generate_Query_Log()
{
	if [ -n "$PPID" ]
	then
		ps | grep -v grep | grep -v $$ | grep -v "$PPID" | grep -i "$SCRIPT_NAME" | grep querylog | awk '{print $1}' | xargs kill -9 >/dev/null 2>&1
	else
		ps | grep -v grep | grep -v $$ | grep -i "$SCRIPT_NAME" | grep querylog | awk '{print $1}' | xargs kill -9 >/dev/null 2>&1
	fi
	local foundError  foundLocked  resultStr

	recordcount="$(LastXQueries check)"
	if [ "$(CacheMode check)" = "tmp" ]
	then
		if [ -f /tmp/cache-uiDivStats-SQL.tmp ]
		then
			tail -n "$recordcount" /tmp/cache-uiDivStats-SQL.tmp | sort -s -k 1,1 -n -r | sed 's/,/|/g' | awk 'BEGIN{FS=OFS="|"} {t=$2; $2=$3; $3=t; print}' > /tmp/cache-uiDivStats-SQL.tmp.ordered
			recordcount="$((recordcount - $(wc -l < /tmp/cache-uiDivStats-SQL.tmp.ordered)))"
			if [ "$(echo "$recordcount 0" | awk '{print ($1 < $2)}')" -eq 1 ]; then
				recordcount=0
			fi
		fi
	fi

	if [ "$recordcount" -gt 0 ]
	then
		{
			echo ".mode csv"
			echo ".headers off"
			echo ".separator '|'"
			echo ".output $CSV_OUTPUT_DIR/SQLQueryLog.tmp"
			echo "PRAGMA temp_store=1;"
			echo "SELECT [Timestamp] Time,[ReqDmn] ReqDmn,[SrcIP] SrcIP,[QryType] QryType,[Allowed] Allowed FROM [dnsqueries] ORDER BY [Timestamp] DESC LIMIT $recordcount;"
		} > /tmp/uidivstats-query.sql
		_ApplyDatabaseSQLCmds_ /tmp/uidivstats-query.sql
		rm -f /tmp/uidivstats-query.sql

		cat /tmp/cache-uiDivStats-SQL.tmp.ordered "$CSV_OUTPUT_DIR/SQLQueryLog.tmp" > "$CSV_OUTPUT_DIR/SQLQueryLog.htm" 2> /dev/null
	else
		mv /tmp/cache-uiDivStats-SQL.tmp.ordered "$CSV_OUTPUT_DIR/SQLQueryLog.htm"
	fi
	rm -f /tmp/cache-uiDivStats-SQL.tmp.ordered
	rm -f "$CSV_OUTPUT_DIR/SQLQueryLog.tmp"

	_UpdateDatabaseFileSizeInfo_
}

##----------------------------------------##
## Modified by Martinski W. [2024-Dec-13] ##
##----------------------------------------##
Generate_KeyStats()
{
	timenow="$1"

	#DAILY#
	Write_KeyStats_Sql_ToFile Total dnsqueries daily /tmp/uidivstats.sql
	_ApplyDatabaseSQLCmds_ /tmp/uidivstats.sql

	Write_KeyStats_Sql_ToFile Blocked dnsqueries daily /tmp/uidivstats.sql
	_ApplyDatabaseSQLCmds_ /tmp/uidivstats.sql
	rm -f /tmp/uidivstats.sql

	queriesTotaldaily="$(cat /tmp/queriesTotaldaily)"
	queriesBlockeddaily="$(cat /tmp/queriesBlockeddaily)"

	if ! Validate_Number "$queriesTotaldaily"; then queriesTotaldaily=0; fi
	if ! Validate_Number "$queriesBlockeddaily"; then queriesBlockeddaily=0; fi
	if [ "$queriesTotaldaily" -eq 0 ]; then
		queriesPercentagedaily=0
	else
		queriesPercentagedaily="$(echo "$queriesBlockeddaily" "$queriesTotaldaily" | awk '{printf "%3.2f\n",$1/$2*100}')"
	fi

	WritePlainData_ToJS "$SCRIPT_USB_DIR/SQLData.js" "QueriesTotaldaily,$queriesTotaldaily" "QueriesBlockeddaily,$queriesBlockeddaily" "BlockedPercentagedaily,$queriesPercentagedaily"

	if [ $# -gt 1 ] && [ -n "$2" ] && [ "$2" = "fullrefresh" ]
	then
		#WEEKLY#
		Write_KeyStats_Sql_ToFile Total dnsqueries weekly /tmp/uidivstats.sql
		_ApplyDatabaseSQLCmds_ /tmp/uidivstats.sql

		Write_KeyStats_Sql_ToFile Blocked dnsqueries weekly /tmp/uidivstats.sql
		_ApplyDatabaseSQLCmds_ /tmp/uidivstats.sql
		rm -f /tmp/uidivstats.sql

		queriesTotalweekly="$(cat /tmp/queriesTotalweekly)"
		queriesBlockedweekly="$(cat /tmp/queriesBlockedweekly)"

		if ! Validate_Number "$queriesTotalweekly"; then queriesTotalweekly=0; fi
		if ! Validate_Number "$queriesBlockedweekly"; then queriesBlockedweekly=0; fi
		if [ "$queriesTotalweekly" -eq 0 ]; then
			queriesPercentageweekly=0
		else
			queriesPercentageweekly="$(echo "$queriesBlockedweekly" "$queriesTotalweekly" | awk '{printf "%3.2f\n",$1/$2*100}')"
		fi

		WritePlainData_ToJS "$SCRIPT_USB_DIR/SQLData.js" "QueriesTotalweekly,$queriesTotalweekly" "QueriesBlockedweekly,$queriesBlockedweekly" "BlockedPercentageweekly,$queriesPercentageweekly"

		#MONTHLY#
		Write_KeyStats_Sql_ToFile Total dnsqueries monthly /tmp/uidivstats.sql
		_ApplyDatabaseSQLCmds_ /tmp/uidivstats.sql

		Write_KeyStats_Sql_ToFile Blocked dnsqueries monthly /tmp/uidivstats.sql
		_ApplyDatabaseSQLCmds_ /tmp/uidivstats.sql

		rm -f /tmp/uidivstats.sql

		queriesTotalmonthly="$(cat /tmp/queriesTotalmonthly)"
		queriesBlockedmonthly="$(cat /tmp/queriesBlockedmonthly)"

		if ! Validate_Number "$queriesTotalmonthly"; then queriesTotalmonthly=0; fi
		if ! Validate_Number "$queriesBlockedmonthly"; then queriesBlockedmonthly=0; fi
		if [ "$queriesTotalmonthly" -eq 0 ]; then
			queriesPercentagemonthly=0
		else
			queriesPercentagemonthly="$(echo "$queriesBlockedmonthly" "$queriesTotalmonthly" | awk '{printf "%3.2f\n",$1/$2*100}')"
		fi

		WritePlainData_ToJS "$SCRIPT_USB_DIR/SQLData.js" "QueriesTotalmonthly,$queriesTotalmonthly" "QueriesBlockedmonthly,$queriesBlockedmonthly" "BlockedPercentagemonthly,$queriesPercentagemonthly"
	fi

	rm -f /tmp/queriesTotal*
	rm -f /tmp/queriesBlocked*
}

Generate_Count_Blocklist_Domains()
{
	blockinglistfile="${DIVERSION_DIR}/list/blockinglist.conf"

	blocklistdomains="$(cat "$blockinglistfile" | wc -l)"

	if ! Validate_Number "$blocklistdomains"; then blocklistdomains=0; fi

	WritePlainData_ToJS "$SCRIPT_USB_DIR/SQLData.js" "BlockedDomains,$blocklistdomains"
}

##----------------------------------------##
## Modified by Martinski W. [2024-Dec-13] ##
##----------------------------------------##
Generate_Stats_From_SQLite()
{
	timenow="$1"

	metriclist="Total Blocked"

	for metric in $metriclist
	do
		#DAILY#
		Write_Time_Sql_ToFile "$metric" dnsqueries 0.25 1 "$CSV_OUTPUT_DIR/$metric" daily /tmp/uidivstats.sql
		_ApplyDatabaseSQLCmds_ /tmp/uidivstats.sql

		Write_Count_Sql_ToFile "$metric" dnsqueries 1 "$CSV_OUTPUT_DIR/$metric" daily /tmp/uidivstats.sql
		_ApplyDatabaseSQLCmds_ /tmp/uidivstats.sql

		Write_Count_PerClient_Sql_ToFile "$metric" dnsqueries 1 "$CSV_OUTPUT_DIR/$metric" daily /tmp/uidivstats.sql
		_ApplyDatabaseSQLCmds_ /tmp/uidivstats.sql
		rm -f /tmp/uidivstats.sql

		sed -i '1i Fieldname,SrcIP,ReqDmn,Count' "$CSV_OUTPUT_DIR/${metric}dailyclients.htm"
		cat "$CSV_OUTPUT_DIR/Totaldailytime.htm" "$CSV_OUTPUT_DIR/Blockeddailytime.htm" > "$CSV_OUTPUT_DIR/TotalBlockeddailytime.htm" 2> /dev/null
		sed -i '1i Fieldname,Time,QueryCount' "$CSV_OUTPUT_DIR/TotalBlockeddailytime.htm"

		#WEEKLY#
		if [ $# -gt 1 ] && [ -n "$2" ] && [ "$2" = "fullrefresh" ]
		then
			Write_Time_Sql_ToFile "$metric" dnsqueries 1 7 "$CSV_OUTPUT_DIR/$metric" weekly /tmp/uidivstats.sql
			_ApplyDatabaseSQLCmds_ /tmp/uidivstats.sql

			Write_Count_Sql_ToFile "$metric" dnsqueries 7 "$CSV_OUTPUT_DIR/$metric" weekly /tmp/uidivstats.sql
			_ApplyDatabaseSQLCmds_ /tmp/uidivstats.sql

			Write_Count_PerClient_Sql_ToFile "$metric" dnsqueries 7 "$CSV_OUTPUT_DIR/$metric" weekly /tmp/uidivstats.sql
			_ApplyDatabaseSQLCmds_ /tmp/uidivstats.sql
			rm -f /tmp/uidivstats.sql

			sed -i '1i Fieldname,SrcIP,ReqDmn,Count' "$CSV_OUTPUT_DIR/${metric}weeklyclients.htm"
			cat "$CSV_OUTPUT_DIR/Totalweeklytime.htm" "$CSV_OUTPUT_DIR/Blockedweeklytime.htm" > "$CSV_OUTPUT_DIR/TotalBlockedweeklytime.htm" 2> /dev/null
			sed -i '1i Fieldname,Time,QueryCount' "$CSV_OUTPUT_DIR/TotalBlockedweeklytime.htm"
		fi

		#MONTHLY#
		if [ $# -gt 1 ] && [ -n "$2" ] && [ "$2" = "fullrefresh" ]
		then
			Write_Time_Sql_ToFile "$metric" dnsqueries 3 30 "$CSV_OUTPUT_DIR/$metric" monthly /tmp/uidivstats.sql
			_ApplyDatabaseSQLCmds_ /tmp/uidivstats.sql

			Write_Count_Sql_ToFile "$metric" dnsqueries 30 "$CSV_OUTPUT_DIR/$metric" monthly /tmp/uidivstats.sql
			_ApplyDatabaseSQLCmds_ /tmp/uidivstats.sql

			Write_Count_PerClient_Sql_ToFile "$metric" dnsqueries 30 "$CSV_OUTPUT_DIR/$metric" monthly /tmp/uidivstats.sql
			_ApplyDatabaseSQLCmds_ /tmp/uidivstats.sql
			rm -f /tmp/uidivstats.sql

			sed -i '1i Fieldname,SrcIP,ReqDmn,Count' "$CSV_OUTPUT_DIR/${metric}monthlyclients.htm"
			cat "$CSV_OUTPUT_DIR/Totalmonthlytime.htm" "$CSV_OUTPUT_DIR/Blockedmonthlytime.htm" > "$CSV_OUTPUT_DIR/TotalBlockedmonthlytime.htm" 2> /dev/null
			sed -i '1i Fieldname,Time,QueryCount' "$CSV_OUTPUT_DIR/TotalBlockedmonthlytime.htm"
		fi
	done

	Write_View_Sql_ToFile drop dnsqueries daily /tmp/uidivstats.sql
	_ApplyDatabaseSQLCmds_ /tmp/uidivstats.sql
	rm -f /tmp/uidivstats.sql

	{
		echo ".mode list"
		echo ".output /tmp/ipdistinctclients"
		echo "PRAGMA temp_store=1;"
		echo "SELECT DISTINCT [SrcIP] SrcIP FROM dnsqueries;"
	} > /tmp/ipdistinctclients.sql
	_ApplyDatabaseSQLCmds_ /tmp/ipdistinctclients.sql
	rm -f /tmp/ipdistinctclients.sql

	ipclients="$(cat /tmp/ipdistinctclients)"
	rm -f /tmp/ipdistinctclients

	if [ ! -f /opt/bin/dig ]; then
		opkg update
		opkg install bind-dig
	fi

	echo "var hostiparray =[" > "$CSV_OUTPUT_DIR/ipdistinctclients.js"
	ARPDUMP="$(arp -an)"
	for ipclient in $ipclients
	do
		ARPINFO="$(echo "$ARPDUMP" | grep "$ipclient)")"
		MACADDR="$(echo "$ARPINFO" | awk '{print $4}' | cut -f1 -d ".")"

		HOST="$(arp "$ipclient" | awk '{if (NR==1) {print $1}}' | cut -f1 -d ".")"
		if [ "$HOST" = "?" ] || [ "$HOST" = "No" ]; then
			HOST="$(grep "$ipclient " /var/lib/misc/dnsmasq.leases | grep -v "\*" | awk '{print $4}')"
		fi

		if [ "$HOST" = "?" ] || [ "$HOST" = "No" ] || [ "$(printf "%s" "$HOST" | wc -m)" -le 1 ]; then
			HOST="$(nvram get custom_clientlist | grep -ioE "<.*>$MACADDR" | awk -F ">" '{print $(NF-1)}' | tr -d '<')" #thanks Adamm00
		fi

		if Validate_IP "$ipclient" >/dev/null 2>&1
		then
			if [ -z "$HOST" ]; then
				HOST="$(dig +short +answer -x "$ipclient" '@'"$(nvram get lan_ipaddr)" | cut -f1 -d'.')"
			fi
		else
			HOST="IPv6"
		fi

		if [ -z "$HOST" ]; then
			HOST="Unknown"
		fi

		HOST="$(echo "$HOST" | tr -d '\n')"

		echo '["'"$ipclient"'","'"$HOST"'"],' >> "$CSV_OUTPUT_DIR/ipdistinctclients.js"
	done
	sed -i '$ s/,$//' "$CSV_OUTPUT_DIR/ipdistinctclients.js"
	echo "];" >> "$CSV_OUTPUT_DIR/ipdistinctclients.js"
}

##-------------------------------------##
## Added by Martinski W. [2024-Oct-26] ##
##-------------------------------------##
_ShowDatabaseFileInfo_()
{
   [ ! -s "$1" ] && echo 0 && return 1
   local fileSize  sizeInfo
   fileSize="$(ls -1lh "$1" | awk -F ' ' '{print $3}')"
   sizeInfo="$(ls -1l "$1" | awk -F ' ' '{print $3,$4,$5,$6,$7}')"
   printf "[%sB] %s\n" "$fileSize" "$sizeInfo"
}

_GetTrimLogTimeStamp_() { printf "[$(date +"$trimLogDateForm")]" ; }

##-------------------------------------##
## Added by Martinski W. [2024-Dec-13] ##
##-------------------------------------##
_ApplyDatabaseSQLCmds_()
{
    local errorCount=0  maxErrorCount=5
    local triesCount=0  maxTriesCount=15  sqlErrorMsg
    local tempLogFilePath="/tmp/uiDivStats_TMP_$$.LOG"

    resultStr=""
    foundError=false ; foundLocked=false
    rm -f "$tempLogFilePath"

    while [ "$errorCount" -lt "$maxErrorCount" ] && \
          [ "$((triesCount++))" -lt "$maxTriesCount" ]
    do
        if "$SQLITE3_PATH" "$DNS_DB" < "$1" >> "$tempLogFilePath" 2>&1
        then foundError=false ; foundLocked=false ; break
        fi
        sqlErrorMsg="$(tail -n1 "$tempLogFilePath")"
        if echo "$sqlErrorMsg" | grep -qE "^(Error:|Parse error|Runtime error)"
        then
            echo "$sqlErrorMsg"
            if echo "$sqlErrorMsg" | grep -qE "^Runtime error .*: database is locked"
            then foundLocked=true ; sleep 2 ; continue
            fi
            errorCount="$((errorCount + 1))"
            foundError=true ; foundLocked=false
            Print_Output true "SQLite3 failure: $sqlErrorMsg" "$ERR"
        fi
        [ "$triesCount" -ge "$maxTriesCount" ] && break
        [ "$errorCount" -ge "$maxErrorCount" ] && break
        sleep 1
    done

    rm -f "$tempLogFilePath"
    if "$foundError"
    then resultStr="reported error(s)."
    elif "$foundLocked"
    then resultStr="found database locked."
    else resultStr="completed successfully."
    fi
    if "$foundError" || "$foundLocked"
    then
        Print_Output true "SQLite process ${resultStr}." "$CRIT"
    fi
}

##----------------------------------------##
## Modified by Martinski W. [2024-Dec-13] ##
##----------------------------------------##
_ApplyDatabaseSQLCmdsForTrim_()
{
    local errorCount=0  maxErrorCount=5
    local triesCount=0  maxTriesCount=15  sqlErrorMsg

    resultStr=""
    foundError=false ; foundLocked=false

    while [ "$errorCount" -lt "$maxErrorCount" ] && \
          [ "$((triesCount++))" -lt "$maxTriesCount" ]
    do
        if "$SQLITE3_PATH" "$DNS_DB" < /tmp/uidivstats-trim.sql >> "$trimLOGFilePath" 2>&1
        then foundError=false ; foundLocked=false ; break
        fi
        sqlErrorMsg="$(tail -n1 "$trimLOGFilePath")"
        echo "-----------------------------------" >> "$trimLOGFilePath"
        printf "$(_GetTrimLogTimeStamp_) TRY_COUNT=[$triesCount]\n" | tee -a "$trimLOGFilePath"
        if echo "$sqlErrorMsg" | grep -qE "^(Error:|Parse error|Runtime error)"
        then
            echo "$sqlErrorMsg"
            if echo "$sqlErrorMsg" | grep -qE "^Runtime error .*: database is locked"
            then foundLocked=true ; sleep 2 ; continue
            fi
            errorCount="$((errorCount + 1))"
            foundError=true ; foundLocked=false
            Print_Output true "SQLite3 failure: $sqlErrorMsg" "$ERR"
        fi
        [ "$triesCount" -ge "$maxTriesCount" ] && break
        [ "$errorCount" -ge "$maxErrorCount" ] && break
        sleep 1
    done

    if "$foundError"
    then resultStr="reported error(s)."
    elif "$foundLocked"
    then resultStr="found database locked."
    else
        resultStr="completed successfully."
        [ "$triesCount" -gt 1 ] && \
        printf "$(_GetTrimLogTimeStamp_) TRY_COUNT=[$triesCount]\n" | tee -a "$trimLOGFilePath"
    fi
}

##----------------------------------------##
## Modified by Martinski W. [2024-Oct-26] ##
##----------------------------------------##
Optimise_DNS_DB()
{
	renice 15 $$

	local foundError  foundLocked  resultStr

	printf "$(_GetTrimLogTimeStamp_) BEGIN [${SCRIPT_VERSION}]\n" | tee -a "$trimLOGFilePath"
	printf "Running database analysis and optimization...\n" | tee -a "$trimLOGFilePath"
	_ShowDatabaseFileInfo_ "$DNS_DB" | tee -a "$trimLOGFilePath"

	Print_Output true "Running nightly database analysis and optimization..." "$PASS"
	{
		echo "PRAGMA temp_store=1;"
		echo "PRAGMA analysis_limit=0;"
		echo "PRAGMA cache_size=-20000;"
		echo "ANALYZE dnsqueries;"
		echo "VACUUM;"
	} > /tmp/uidivstats-trim.sql

	_ApplyDatabaseSQLCmdsForTrim_
	_ShowDatabaseFileInfo_ "$DNS_DB" | tee -a "$trimLOGFilePath"
	printf "Database analysis and optimization process ${resultStr}\n" | tee -a "$trimLOGFilePath"
	printf "$(_GetTrimLogTimeStamp_) END.\n" | tee -a "$trimLOGFilePath"
	echo "========================================" >> "$trimLOGFilePath"

	rm -f /tmp/uidivstats-trim.sql
	Print_Output true "Database analysis and optimization completed." "$PASS"

	renice 0 $$
}

##----------------------------------------##
## Modified by Martinski W. [2024-Oct-27] ##
##----------------------------------------##
Trim_DNS_DB()
{
	Check_Lock
	renice 15 $$
	TZ="$(cat /etc/TZ)"
	export TZ
	timeNow="$(date +'%s')"

	local foundError  foundLocked  resultStr
	local trimErrorsFound  trimNumLocked

	if [ "$(_GetFileSize_ "$trimLOGFilePath")" -gt "$trimLOGFileSize" ]
	then
	    cp -fp "$trimLOGFilePath" "${trimLOGFilePath}.BAK"
	    rm -f "$trimLOGFilePath"
	fi
	touch "$trimLOGFilePath"
	trimNumLocked=0
	trimErrorsFound=false

	printf "$(_GetTrimLogTimeStamp_) BEGIN [${SCRIPT_VERSION}]\n" | tee -a "$trimLOGFilePath"
	printf "Trimming database records older than [$(DaysToKeep check)] days...\n" | tee -a "$trimLOGFilePath"
	_ShowDatabaseFileInfo_ "$DNS_DB" | tee -a "$trimLOGFilePath"

	Print_Output true "Trimming records entries from database..." "$PASS"
	{
		echo "PRAGMA temp_store=1;"
		echo "PRAGMA cache_size=-20000;"
		echo "BEGIN TRANSACTION;"
		echo "DELETE FROM [dnsqueries] WHERE [Timestamp] < strftime('%s',datetime($timeNow,'unixepoch','-$(DaysToKeep check) day'));"
		echo "DELETE FROM [dnsqueries] WHERE [Timestamp] > $timeNow;"
		echo "DELETE FROM [dnsqueries] WHERE [SrcIP] = 'from';"
		echo "END TRANSACTION;"
	} > /tmp/uidivstats-trim.sql

	_ApplyDatabaseSQLCmdsForTrim_
	"$foundError" && trimErrorsFound=true
	"$foundLocked" && trimNumLocked="$((trimNumLocked + 1))"
	printf "$(_GetTrimLogTimeStamp_) Database record trimming process ${resultStr}\n" | tee -a "$trimLOGFilePath"

	Write_View_Sql_ToFile drop dnsqueries weekly /tmp/uidivstats-trim.sql
	_ApplyDatabaseSQLCmdsForTrim_
	"$foundError" && trimErrorsFound=true
	"$foundLocked" && trimNumLocked="$((trimNumLocked + 1))"
	printf "$(_GetTrimLogTimeStamp_) Database weekly view removal process ${resultStr}\n" | tee -a "$trimLOGFilePath"

	Write_View_Sql_ToFile drop dnsqueries monthly /tmp/uidivstats-trim.sql
	_ApplyDatabaseSQLCmdsForTrim_
	"$foundError" && trimErrorsFound=true
	"$foundLocked" && trimNumLocked="$((trimNumLocked + 1))"
	printf "$(_GetTrimLogTimeStamp_) Database monthly view removal process ${resultStr}\n" | tee -a "$trimLOGFilePath"

	rm -f /tmp/uidivstats-trim.sql
	Print_Output true "Database record trimming completed." "$PASS"

	if "$trimErrorsFound"
	then resultStr="reported error(s)."
	elif [ "$trimNumLocked" -gt 2 ]
	then resultStr="found locked database."
	else resultStr="completed successfully."
	fi
	_ShowDatabaseFileInfo_ "$DNS_DB" | tee -a "$trimLOGFilePath"
	printf "Database trimming process ${resultStr}\n" | tee -a "$trimLOGFilePath"
	printf "$(_GetTrimLogTimeStamp_) END.\n\n" | tee -a "$trimLOGFilePath"

	renice 0 $$
	Clear_Lock
}

##----------------------------------------##
## Modified by Martinski W. [2024-Dec-13] ##
##----------------------------------------##
Flush_Cache_To_DB()
{
	if [ -n "$PPID" ]
	then
		ps | grep -v grep | grep -v $$ | grep -v "$PPID" | grep -i "$SCRIPT_NAME" | grep flushtodb | awk '{print $1}' | xargs kill -9 >/dev/null 2>&1
	else
		ps | grep -v grep | grep -v $$ | grep -i "$SCRIPT_NAME" | grep flushtodb | awk '{print $1}' | xargs kill -9 >/dev/null 2>&1
	fi
	local foundError  foundLocked  resultStr 

	renice 15 $$
	if [ -f /tmp/cache-uiDivStats-SQL.tmp ]
	then
		{
			echo "PRAGMA temp_store=1;"
			echo "PRAGMA synchronous = normal;"
			echo "PRAGMA cache_size=-20000;"
			echo "BEGIN TRANSACTION;"
			echo "CREATE TABLE IF NOT EXISTS [dnsqueries] ([QueryID] INTEGER PRIMARY KEY NOT NULL,[Timestamp] NUMERIC NOT NULL,[SrcIP] TEXT NOT NULL,[ReqDmn] TEXT NOT NULL,[QryType] Text NOT NULL,[Allowed] INTEGER NOT NULL);"
			echo "CREATE TABLE IF NOT EXISTS [dnsqueries_tmp] ([Timestamp] NUMERIC NOT NULL,[SrcIP] TEXT NOT NULL,[ReqDmn] TEXT NOT NULL,[QryType] Text NOT NULL,[Allowed] INTEGER NOT NULL);"
			echo ".mode csv"
			echo ".import /tmp/cache-uiDivStats-SQL.tmp dnsqueries_tmp"
			echo "INSERT INTO dnsqueries SELECT NULL,* FROM dnsqueries_tmp;"
			echo "DROP TABLE IF EXISTS dnsqueries_tmp;"
			echo "END TRANSACTION;"
		} > /tmp/cache-uiDivStats-SQL.sql
		_ApplyDatabaseSQLCmds_ /tmp/cache-uiDivStats-SQL.sql

		rm -f /tmp/cache-uiDivStats-SQL.sql
		rm -f /tmp/cache-uiDivStats-SQL.tmp
	fi
	renice 0 $$
}

##----------------------------------------##
## Modified by Martinski W. [2024-Dec-13] ##
##----------------------------------------##
Reset_DB()
{
	local foundError  foundLocked  resultStr

	/opt/etc/init.d/S90taildns stop >/dev/null 2>&1
	sleep 3
	Auto_Cron delete 2>/dev/null

	if ! mv -f "$DNS_DB" "${DNS_DB}$1"; then
		Print_Output true "Database backup failed, please check storage device" "$WARN"
	fi

	Print_Output false "Creating database table and enabling write-ahead logging..." "$PASS"
	{
		echo "PRAGMA journal_mode=WAL;"
		echo "PRAGMA temp_store=1;"
		echo "CREATE TABLE IF NOT EXISTS [dnsqueries] ([QueryID] INTEGER PRIMARY KEY NOT NULL,[Timestamp] NUMERIC NOT NULL,[SrcIP] TEXT NOT NULL,[ReqDmn] TEXT NOT NULL,[QryType] Text NOT NULL,[Allowed] INTEGER NOT NULL);"
	}  > /tmp/uidivstats-upgrade.sql

	_ApplyDatabaseSQLCmds_ /tmp/uidivstats-upgrade.sql
	if "$foundError" || "$foundLocked"
	then
		Print_Output true "Unable to create database file." "$CRIT"
		return 1
	fi

	Print_Output false "Creating database table indexes..." "$PASS"
	Table_Indexes drop
	Table_Indexes create
	rm -f /tmp/uidivstats-upgrade.sql

	if ! "$foundError" && ! "$foundLocked"
	then
		Print_Output false "Database ready, starting services..." "$PASS"
	fi
	renice 0 $$

	if "$dbBackgProcsEnabled"
	then
		Auto_Cron create 2>/dev/null
		/opt/etc/init.d/S90taildns start >/dev/null 2>&1
	fi

	Print_Output true "Database reset complete" "$WARN"
}

Process_Upgrade()
{
	if [ -f "$SCRIPT_DIR/.upgraded" ] || [ -f "$SCRIPT_DIR/.upgraded2" ] || [ -f "$SCRIPT_DIR/.upgraded3" ]
	then
		Print_Output true "Unable to upgrade from older versions than 3.0.0" "$CRIT"
		exit 1
	fi

	rm -f "$SCRIPT_DIR/.newindexes"

	if echo "SELECT [Result] FROM [dnsqueries] LIMIT 0" | "$SQLITE3_PATH" "$DNS_DB" >/dev/null 2>&1
	then
		Print_Output true "Upgrade database schema." "$WARN"
		Print_Output false "Existing data will be migrated overnight, or you can run 'uiDivStats trimdb' manually." "$WARN"
		Reset_DB ".old"
	fi
}

Migrate_Old_Data()
{
	if [ -f "${DNS_DB}.old" ]
	then
		Print_Output true "Migrating old data. This can take a while!" "$PASS"
		Auto_Cron delete 2>/dev/null
		renice 15 $$

		TZ="$(cat /etc/TZ)"
		export TZ
		timenow="$(date +'%s')"
		{
			echo "ATTACH DATABASE '$DNS_DB.old' AS OLD;"
			echo "INSERT INTO [dnsqueries] ([Timestamp], [SrcIP], [ReqDmn], [QryType], [Allowed]) SELECT [Timestamp], [SrcIP], [ReqDmn], CASE [QryType] WHEN 'type=65' THEN 'HTTPS' ELSE [QryType] END, [Result] == 'allowed' FROM OLD.[dnsqueries] WHERE [Timestamp] > strftime('%s',datetime($timenow,'unixepoch','-$(DaysToKeep check) day'));"
		} > /tmp/uidivstats-upgrade.sql
		_ApplyDatabaseSQLCmds_ /tmp/uidivstats-upgrade.sql

		rm -f /tmp/uidivstats-upgrade.sql
		rm -f "${DNS_DB}.old"

		Print_Output true "Data migration complete" "$PASS"
		Auto_Cron create 2>/dev/null
		renice 0 $$
	fi
}

Shortcut_Script(){
	case $1 in
		create)
			if [ -d /opt/bin ] && [ ! -f "/opt/bin/$SCRIPT_NAME" ] && [ -f "/jffs/scripts/$SCRIPT_NAME" ]; then
				ln -s "/jffs/scripts/$SCRIPT_NAME" /opt/bin
				chmod 0755 "/opt/bin/$SCRIPT_NAME"
			fi
		;;
		delete)
			if [ -f "/opt/bin/$SCRIPT_NAME" ]; then
				rm -f "/opt/bin/$SCRIPT_NAME"
			fi
		;;
	esac
}

PressEnter()
{
	while true
	do
		printf "Press <Enter> key to continue..."
		read -rs key
		case "$key" in
			*) break ;;
		esac
	done
	return 0
}

##-------------------------------------##
## Added by Martinski W. [2024-Dec-13] ##
##-------------------------------------##
_WaitForYESorNO_()
{
   local thePromptStr
   if [ $# -eq 0 ] || [ -z "$1" ]
   then thePromptStr=" [yY|nN]?  "
   else thePromptStr="$1 [yY|nN]?  "
   fi
   printf "$thePromptStr" ; read -r YESorNO
   if echo "$YESorNO" | grep -qE "^([Yy](es)?|YES)$"
   then echo "OK" ; return 0
   else echo "NO" ; return 1
   fi
}

ScriptHeader()
{
	clear
	printf "\\n"
	printf "${BOLD}###################################################################${CLEARFORMAT}\\n"
	printf "${BOLD}##                                                               ##${CLEARFORMAT}\\n"
	printf "${BOLD}##           _  _____   _          _____  _          _           ##${CLEARFORMAT}\\n"
	printf "${BOLD}##          (_)|  __ \ (_)        / ____|| |        | |          ##${CLEARFORMAT}\\n"
	printf "${BOLD}##    _   _  _ | |  | | _ __   __| (___  | |_  __ _ | |_  ___    ##${CLEARFORMAT}\\n"
	printf "${BOLD}##   | | | || || |  | || |\ \ / / \___ \ | __|/ _  || __|/ __|   ##${CLEARFORMAT}\\n"
	printf "${BOLD}##   | |_| || || |__| || | \ V /  ____) || |_| (_| || |_ \__ \   ##${CLEARFORMAT}\\n"
	printf "${BOLD}##    \__,_||_||_____/ |_|  \_/  |_____/  \__|\__,_| \__||___/   ##${CLEARFORMAT}\\n"
	printf "${BOLD}##                                                               ##${CLEARFORMAT}\\n"
	printf "${BOLD}##                     %s on %-18s              ##${CLEARFORMAT}\\n" "$SCRIPT_VERSION" "$ROUTER_MODEL"
	printf "${BOLD}##                                                               ##${CLEARFORMAT}\\n"
	printf "${BOLD}##              https://github.com/jackyaz/uiDivStats            ##${CLEARFORMAT}\\n"
	printf "${BOLD}##                                                               ##${CLEARFORMAT}\\n"
	printf "${BOLD}###################################################################${CLEARFORMAT}\\n"
	printf "\\n"
}

##----------------------------------------##
## Modified by Martinski W. [2024-Dec-14] ##
##----------------------------------------##
MainMenu()
{
	local statusBackProcsState  statusBackProcsColor  statusBackProcsWarning
    local cacheModeStr  menuOpt  tmpInfoStr  memInfoStr

	_InvalidMenuOptionMsg_()
	{
       [ -n "$1" ] && \
       printf "\n${REDct}INVALID input [$1]${CLEARFORMAT}"
	   printf "\nPlease choose a valid option.\n\n"
	}

	if "$(_ToggleBackgroundProcsEnabled_ check)"
	then
	    statusBackProcsColor="$GRNct"
	    statusBackProcsState="ENABLED"
	    statusBackProcsWarning=""
	else
	    statusBackProcsColor="$REDct"
	    statusBackProcsState="DISABLED"
	    statusBackProcsWarning="${WARN} <<--- *WARNING*"
	fi

	if [ "$(CacheMode check)" = "none" ]
	then cacheModeStr="none"
	else cacheModeStr="TMPFS"
	fi

	printf "WebUI for %s is available at:\n${SETTING}%s${CLEARFORMAT}\n\n" "$SCRIPT_NAME" "$(Get_WebUI_URL)"
	printf "1.    Update Diversion Statistics (daily only)\n"
	printf "      Database size: ${SETTING}%s${CLEARFORMAT}\n\n" "$(_GetFileSize_ "$DNS_DB" HRx)"
	printf "2.    Update Diversion Statistics (daily, weekly and monthly)\n"
	printf "      WARNING: THIS MAY TAKE A WHILE (>5 minutes)\n\n"
	printf "3.    Edit list of domains to exclude from %s statistics\n\n" "$SCRIPT_NAME"
	printf "4.    Set number of recent DNS queries to show in WebUI\n"
	printf "      Currently: ${SETTING}%s queries will be shown${CLEARFORMAT}\n\n" "$(LastXQueries check)"
	printf "5.    Set number of days data to keep in database\n"
	printf "      Currently: ${SETTING}%s days data will be kept${CLEARFORMAT}\n\n" "$(DaysToKeep check)"
	printf "6.    Set the hour for daily cron job to trim the database\n"
	printf "      Currently: ${SETTING}%s${CLEARFORMAT}\n\n" "$(_TrimDatabaseTime_ timeHRx)"
	printf "p.    Toggle background processing of Diversion statistics\n"
	printf "      Currently: ${statusBackProcsColor}%s  ${statusBackProcsWarning}${CLEARFORMAT}\n\n" "$statusBackProcsState"
	printf "q.    Toggle query mode\n"
	printf "      Currently: ${SETTING}%s${CLEARFORMAT} query types will be logged\n\n" "$(QueryMode check)"
	printf "c.    Toggle cache mode\n"
	printf "      Currently: ${SETTING}%s${CLEARFORMAT} being used to cache query records\n" "$cacheModeStr"
	if [ "$cacheModeStr" = "none" ]
	then printf "\n"
	else
        tmpInfoStr="$(_Get_TMPFS_Space_ FREE HR)" ; memInfoStr="$(_GetAvailableRAM_ HRx)"
        printf "      TMPFS Available: ${SETTING}%s${CLEARFORMAT}   RAM Available: ${SETTING}%s${CLEARFORMAT}\n\n" "$tmpInfoStr" "$memInfoStr"
	fi
	printf "u.    Check for updates\n"
	printf "uf.   Update %s with latest version (force update)\n\n" "$SCRIPT_NAME"
	printf "r.    Reset %s database / delete all data\n\n" "$SCRIPT_NAME"
	printf "e.    Exit %s\n\n" "$SCRIPT_NAME"
	printf "z.    Uninstall %s\n" "$SCRIPT_NAME"
	printf "\n"
	printf "${BOLD}###################################################################${CLEARFORMAT}\n"
	printf "\n"

	while true
	do
		printf "Choose an option:  " ; read -r menuOpt
		case "$menuOpt" in
			1)
				printf "\n"
				if Check_Lock menu; then
					Menu_GenerateStats
				fi
				PressEnter
				break
			;;
			2)
				printf "\n"
				if Check_Lock menu; then
					Menu_GenerateStats fullrefresh
				fi
				PressEnter
				break
			;;
			3)
				printf "\n"
				if Check_Lock menu; then
					Menu_EditExcludeList
				fi
				printf "\n"
				PressEnter
				break
			;;
			4)
				printf "\n"
				LastXQueries update && PressEnter
				break
			;;
			5)
				printf "\n"
				DaysToKeep update && PressEnter
				break
			;;
			6)
				printf "\n"
				_TrimDatabaseTime_ update && PressEnter
				break
			;;
			p)
				printf "\n"
				if Check_Lock menu
				then
				    _ToggleBackgroundProcsEnabled_
				    Clear_Lock
				    if "$dbBackgProcsEnabled" && \
				       [ "$statusBackProcsState" = "DISABLED" ]
				    then
				        PressEnter ; exec "$0" ; exit 0
				    fi
				fi
				PressEnter
				break
			;;
			q)
				printf "\n"
				if Check_Lock menu; then
					if [ "$(QueryMode check)" = "all" ]; then
						QueryMode "A+AAAA+HTTPS"
					elif [ "$(QueryMode check)" = "A+AAAA+HTTPS" ]; then
						QueryMode all
					fi
					Clear_Lock
				fi
				break
			;;
			c)
				printf "\n"
				if Check_Lock menu; then
					if [ "$(CacheMode check)" = "none" ]; then
						CacheMode tmp
					elif [ "$(CacheMode check)" = "tmp" ]; then
						CacheMode none
					fi
					Clear_Lock
				fi
				break
			;;
			u)
				printf "\n"
				if Check_Lock menu; then
					Update_Version
					Clear_Lock
				fi
				PressEnter
				break
			;;
			uf)
				printf "\n"
				if Check_Lock menu; then
					Update_Version force
					Clear_Lock
				fi
				PressEnter
				break
			;;
			r)
				printf "\n"
				if Check_Lock menu; then
					Menu_ResetDB
					Clear_Lock
				fi
				PressEnter
				break
			;;
			e)
				ScriptHeader
				printf "\\n${BOLD}Thanks for using %s!${CLEARFORMAT}\\n\\n\\n" "$SCRIPT_NAME"
				exit 0
			;;
			z)
				while true; do
					printf "\\n${BOLD}Are you sure you want to uninstall %s? (y/n)${CLEARFORMAT}  " "$SCRIPT_NAME"
					read -r confirm
					case "$confirm" in
						y|Y)
							Menu_Uninstall
							exit 0
						;;
						*)
							break
						;;
					esac
				done
				break
			;;
			*)
				_InvalidMenuOptionMsg_ "$menuOpt"
				PressEnter
				break
			;;
		esac
	done

	ScriptHeader
	MainMenu
}

Check_Requirements()
{
	CHECKSFAILED="false"

	if [ "$(nvram get jffs2_scripts)" -ne 1 ]; then
		nvram set jffs2_scripts=1
		nvram commit
		Print_Output true "Custom JFFS Scripts enabled" "$WARN"
	fi

	if [ ! -f /opt/bin/opkg ]; then
		Print_Output false "Entware not detected!" "$CRIT"
		CHECKSFAILED="true"
	fi

	if [ ! -f /opt/bin/diversion ]; then
		Print_Output false "Diversion not installed!" "$CRIT"
		CHECKSFAILED="true"
	else
		if ! /opt/bin/grep -qm1 'div_lock_ac' /opt/bin/diversion; then
			Print_Output false "Diversion update required!" "$ERR"
			Print_Output false "Open Diversion and use option u to update"
			CHECKSFAILED="true"
		fi

		if ! /opt/bin/grep -q '^log-facility=/opt/var/log/dnsmasq.log' /etc/dnsmasq.conf
		then
			Print_Output false "Diversion logging not enabled!" "$ERR"
			Print_Output false "Open Diversion and use option l to enable logging"
			CHECKSFAILED="true"
		fi
	fi

	if ! Firmware_Version_Check; then
		Print_Output false "Unsupported firmware version detected, 384.XX required" "$ERR"
		CHECKSFAILED="true"
	fi

	if [ "$CHECKSFAILED" = "false" ]
	then
		opkg update
		opkg install grep
		opkg install sqlite3-cli
		opkg install procps-ng-pkill
		opkg install findutils
		opkg install bind-dig
		return 0
	else
		return 1
	fi
}

##----------------------------------------##
## Modified by Martinski W. [2024-Dec-13] ##
##----------------------------------------##
Menu_Install()
{
	ScriptHeader
	Print_Output true "Welcome to $SCRIPT_NAME $SCRIPT_VERSION, a script by JackYaz" "$PASS"
	sleep 1

	Print_Output false "Checking if your router meets the requirements for $SCRIPT_NAME" "$PASS"

	if ! Check_Requirements
	then
		Print_Output false "Requirements for $SCRIPT_NAME not met, please see above for the reason(s)" "$CRIT"
		PressEnter
		Clear_Lock
		rm -f "/jffs/scripts/$SCRIPT_NAME" 2>/dev/null
		exit 1
	fi
	local foundError  foundLocked  resultStr

	Create_Dirs
	Conf_Exists
	Set_Version_Custom_Settings local "$SCRIPT_VERSION"
	Set_Version_Custom_Settings server "$SCRIPT_VERSION"
	Create_Symlinks

	Update_File uidivstats_www.asp
	Update_File shared-jy.tar.gz
	Update_File taildns.tar.gz

	/opt/etc/init.d/S90taildns stop >/dev/null 2>&1
	sleep 3
	Auto_Cron delete 2>/dev/null

	Process_Upgrade

	renice 15 $$
	Print_Output false "Creating database table and enabling write-ahead logging..." "$PASS"
	{
		echo "PRAGMA journal_mode=WAL;"
		echo "PRAGMA temp_store=1;"
		echo "CREATE TABLE IF NOT EXISTS [dnsqueries] ([QueryID] INTEGER PRIMARY KEY NOT NULL,[Timestamp] NUMERIC NOT NULL,[SrcIP] TEXT NOT NULL,[ReqDmn] TEXT NOT NULL,[QryType] Text NOT NULL,[Allowed] INTEGER NOT NULL);"
	}  > /tmp/uidivstats-upgrade.sql

	_ApplyDatabaseSQLCmds_ /tmp/uidivstats-upgrade.sql
	if "$foundError" || "$foundLocked"
	then
		Print_Output true "Unable to create database file." "$CRIT"
	fi

	Print_Output false "Creating database table indexes..." "$PASS"
	Table_Indexes drop
	Table_Indexes create
	rm -f /tmp/uidivstats-upgrade.sql

	if ! "$foundError" && ! "$foundLocked"
	then
		Print_Output false "Database ready, starting services..." "$PASS"
	fi
	renice 0 $$

	Auto_Startup create 2>/dev/null
	Auto_DNSMASQ_Postconf create 2>/dev/null
	Auto_Cron create 2>/dev/null
	Auto_ServiceEvent create 2>/dev/null
	Shortcut_Script create
	/opt/etc/init.d/S90taildns start >/dev/null 2>&1

	dig +short +answer snbforums.com '@'"$(nvram get lan_ipaddr)" >/dev/null 2>&1
	sleep 1
	dig +short +answer diversion-adblocking-ip.address '@'"$(nvram get lan_ipaddr)" >/dev/null 2>&1
	sleep 1

	Flush_Cache_To_DB
	sleep 1
	Generate_Query_Log
	sleep 1

	Menu_GenerateStats fullrefresh

	Clear_Lock
	ScriptHeader
	MainMenu
}

##----------------------------------------##
## Modified by Martinski W. [2024-Dec-13] ##
##----------------------------------------##
Menu_Startup()
{
	Create_Dirs
	Conf_Exists
	Create_Symlinks
	NTP_Ready

	if [ $# -eq 0 ] || [ -z "$1" ]
	then
		Print_Output true "Missing argument for startup, not starting $SCRIPT_NAME" "$ERR"
		exit 1
	elif [ "$1" != "force" ]
	then
		if [ ! -x "${1}/entware/bin/opkg" ]
		then
			if "$dbBackgProcsEnabled"
			then
			    Print_Output true "$1 does NOT contain Entware, not starting $SCRIPT_NAME" "$CRIT"
			    exit 1
			else
			    Print_Output true "$1 does NOT contain Entware, starting $SCRIPT_NAME with extremely limited functionality." "$ERR"
			fi
		else
			Print_Output true "$1 contains Entware, starting $SCRIPT_NAME" "$PASS"
		fi
	fi

	Check_Lock
	if [ "$1" != "force" ]; then
		sleep 20
	fi
	Auto_Startup create 2>/dev/null
	Auto_DNSMASQ_Postconf create 2>/dev/null
	"$dbBackgProcsEnabled" && Auto_Cron create 2>/dev/null
	Auto_ServiceEvent create 2>/dev/null
	Shortcut_Script create
	Mount_WebUI
	Clear_Lock
}

Menu_GenerateStats()
{
	if [ -f /opt/bin/opkg ] && \
       /opt/bin/grep -q '^log-facility=/opt/var/log/dnsmasq.log' /etc/dnsmasq.conf
	then
		echo 'var uidivstatsstatus = "InProgress";' > /tmp/detect_uidivstats.js
		renice 15 $$
		if [ $# -gt 0 ] && [ -n "$1" ] && [ "$1" = "fullrefresh" ]
		then
			Print_Output true "Starting stat full refresh" "$PASS"
		else
			Print_Output true "Starting stat update" "$PASS"
		fi
		UpdateDiversionWeeklyStatsFile
		Generate_NG "$@"
		renice 0 $$
	else
		Print_Output true "Diversion logging not enabled!" "$ERR"
		Print_Output true "Open Diversion and use option l to enable logging" "$SETTING"
	fi
	Clear_Lock
}

Menu_EditExcludeList()
{
	ScriptHeader
	texteditor=""
	exitmenu="false"

	printf "${BOLD}${WARN}Enter one domain per line${CLEARFORMAT}\\n" "$SCRIPT_NAME"
	printf "\\nThis file is located here: %s\\n" "$STATSEXCLUDE_LIST_FILE"
	printf "\\n\\n${BOLD}A choice of text editors is available:${CLEARFORMAT}\\n"
	printf "1.    nano (recommended for beginners)\\n"
	printf "2.    vi\\n"
	printf "\\ne.    Exit to main menu\\n"

	while true
	do
		printf "\\n${BOLD}Choose an option:${CLEARFORMAT}  "
		read -r editor
		case "$editor" in
			1)
				texteditor="nano -K"
				break
			;;
			2)
				texteditor="vi"
				break
			;;
			e)
				exitmenu="true"
				break
			;;
			*)
				printf "\\nPlease choose a valid option\\n\\n"
			;;
		esac
	done

	if [ "$exitmenu" != "true" ]
	then
		oldmd5="$(md5sum "$STATSEXCLUDE_LIST_FILE" | awk '{print $1}')"
		$texteditor "$STATSEXCLUDE_LIST_FILE"
		newmd5="$(md5sum "$STATSEXCLUDE_LIST_FILE" | awk '{print $1}')"
		if [ "$oldmd5" != "$newmd5" ]
		then
			ScriptHeader
			printf "\\n${BOLD}${WARN}Changes detected, would you like to regenerate stats?${CLEARFORMAT}\\n\\n"
			printf "1.    Daily stats only\\n"
			printf "2.    Daily, weekly and monthly (may take a while, >5 mins)\\n"
			printf "\\ne.    Exit to main menu\\n"

			while true
			do
				printf "\\n${BOLD}Choose an option:${CLEARFORMAT}  "
				read -r editor
				case "$editor" in
					1)
						printf "\\n"
						Menu_GenerateStats
						break
					;;
					2)
						printf "\\n"
						Menu_GenerateStats fullrefresh
						break
					;;
					e)
						break
					;;
					*)
						printf "\\nPlease choose a valid option\\n\\n"
					;;
				esac
			done
		fi
	fi
	Clear_Lock
}

Menu_ResetDB()
{
	printf "${REDct}*WARNING*${CLEARFORMAT}${BOLD}${WARN}\n"
    printf "This will reset the %s database by deleting all database records.\n" "$SCRIPT_NAME"
	printf "A backup of the database file will be created if you change your mind.${CLEARFORMAT}\n"
	printf "\n${BOLD}Do you want to continue? (y/n)${CLEARFORMAT}  "
	read -r confirm
	case "$confirm" in
		y|Y)
			printf "\n"
			Reset_DB ".bak"
		;;
		*)
			printf "\n${BOLD}${WARN}Database reset cancelled${CLEARFORMAT}\n\n"
		;;
	esac
}

Menu_Uninstall()
{
	if [ -n "$PPID" ]; then
		ps | grep -v grep | grep -v $$ | grep -v "$PPID" | grep -i "$SCRIPT_NAME" | grep querylog | awk '{print $1}' | xargs kill -9 >/dev/null 2>&1
	else
		ps | grep -v grep | grep -v $$ | grep -i "$SCRIPT_NAME" | grep querylog | awk '{print $1}' | xargs kill -9 >/dev/null 2>&1
	fi
	if [ -n "$PPID" ]; then
		ps | grep -v grep | grep -v $$ | grep -v "$PPID" | grep -i "$SCRIPT_NAME" | grep flushtodb | awk '{print $1}' | xargs kill -9 >/dev/null 2>&1
	else
		ps | grep -v grep | grep -v $$ | grep -i "$SCRIPT_NAME" | grep flushtodb | awk '{print $1}' | xargs kill -9 >/dev/null 2>&1
	fi
	if [ -n "$PPID" ]; then
		ps | grep -v grep | grep -v $$ | grep -v "$PPID" | grep -i "$SCRIPT_NAME" | grep flushtodb | awk '{print $1}' | xargs kill -9 >/dev/null 2>&1
	else
		ps | grep -v grep | grep -v $$ | grep -i "$SCRIPT_NAME" | grep flushtodb | awk '{print $1}' | xargs kill -9 >/dev/null 2>&1
	fi
	if [ -n "$PPID" ]; then
		ps | grep -v grep | grep -v $$ | grep -v "$PPID" | grep -i "$SCRIPT_NAME" | grep trimdb | awk '{print $1}' | xargs kill -9 >/dev/null 2>&1
	else
		ps | grep -v grep | grep -v $$ | grep -i "$SCRIPT_NAME" | grep trimdb | awk '{print $1}' | xargs kill -9 >/dev/null 2>&1
	fi
	if [ -n "$PPID" ]; then
		ps | grep -v grep | grep -v $$ | grep -v "$PPID" | grep -i "$SCRIPT_NAME" | grep generate | awk '{print $1}' | xargs kill -9 >/dev/null 2>&1
	else
		ps | grep -v grep | grep -v $$ | grep -i "$SCRIPT_NAME" | grep generate | awk '{print $1}' | xargs kill -9 >/dev/null 2>&1
	fi
	Print_Output true "Removing $SCRIPT_NAME..." "$PASS"
	Auto_Startup delete 2>/dev/null
	Auto_DNSMASQ_Postconf delete 2>/dev/null
	Auto_Cron delete 2>/dev/null
	Auto_ServiceEvent delete 2>/dev/null

	Shortcut_Script delete

	LOCKFILE=/tmp/addonwebui.lock
	FD=386
	eval exec "$FD>$LOCKFILE"
	flock -x "$FD"
	Get_WebUI_Page "$SCRIPT_DIR/uidivstats_www.asp"
	if [ -n "$MyPage" ] && [ "$MyPage" != "none" ] && [ -f "/tmp/menuTree.js" ]
	then
		sed -i "\\~$MyPage~d" /tmp/menuTree.js
		umount /www/require/modules/menuTree.js
		mount -o bind /tmp/menuTree.js /www/require/modules/menuTree.js
		rm -f "$SCRIPT_WEBPAGE_DIR/$MyPage"
		rm -f "$SCRIPT_WEBPAGE_DIR/$(echo $MyPage | cut -f1 -d'.').title"
	fi
	flock -u "$FD"
	rm -f "$SCRIPT_DIR/uidivstats_www.asp" 2>/dev/null
	rm -rf "$SCRIPT_WEB_DIR" 2>/dev/null

	SETTINGSFILE="/jffs/addons/custom_settings.txt"
	sed -i '/uidivstats_version_local/d' "$SETTINGSFILE"
	sed -i '/uidivstats_version_server/d' "$SETTINGSFILE"

	/opt/etc/init.d/S90taildns stop >/dev/null 2>&1
	sleep 3
	rm -f /opt/etc/init.d/S90taildns 2>/dev/null
	rm -rf "$SCRIPT_DIR/taildns.d" 2>/dev/null
	rm -f "$SCRIPT_DIR/taildns.tar.gz.md5" 2>/dev/null
	rm -f /tmp/cache-uiDivStats-SQL.tmp*

	printf "\\n\\e[1mDo you want to delete %s stats and config? (y/n)\\e[0m  " "$SCRIPT_NAME"
	read -r confirm
	case "$confirm" in
		y|Y)
			rm -rf "$SCRIPT_DIR" 2>/dev/null
			rm -rf "$SCRIPT_USB_DIR" 2>/dev/null
		;;
		*)
			:
		;;
	esac

	rm -rf "$CSV_OUTPUT_DIR"
	rm -f "$SCRIPT_USB_DIR/SQLData.js"
	rm -f "/jffs/scripts/$SCRIPT_NAME" 2>/dev/null
	Clear_Lock
	Print_Output true "Uninstall completed" "$PASS"
}

NTP_Ready()
{
	if [ "$(nvram get ntp_ready)" -eq 0 ]
	then
		Check_Lock
		ntpwaitcount=0
		while [ "$(nvram get ntp_ready)" -eq 0 ] && [ "$ntpwaitcount" -lt 600 ]
		do
			ntpwaitcount="$((ntpwaitcount + 30))"
			Print_Output true "Waiting for NTP to sync..." "$WARN"
			sleep 30
		done
		if [ "$ntpwaitcount" -ge 600 ]
		then
			Print_Output true "NTP failed to sync after 10 minutes. Please resolve!" "$CRIT"
			Clear_Lock
			exit 1
		else
			Print_Output true "NTP synced, $SCRIPT_NAME will now continue" "$PASS"
			Clear_Lock
		fi
	fi
}

### function based on @Adamm00's Skynet USB wait function ###
##----------------------------------------##
## Modified by Martinski W. [2024-Dec-13] ##
##----------------------------------------##
Entware_Ready()
{
	local theSleepDelay=5  maxSleepTimer=100  sleepTimerSecs
    local doExitNotFound=true

	if [ $# -eq 1 ] && [ "$1" = "false" ]
	then
		theSleepDelay=2
		maxSleepTimer=2
		doExitNotFound=false
	fi

	if [ ! -f /opt/bin/opkg ]
	then
		Check_Lock
		sleepTimerSecs=0

		while [ ! -f /opt/bin/opkg ] && [ "$sleepTimerSecs" -lt "$maxSleepTimer" ]
		do
            if [ "$((sleepTimerSecs % 10))" -eq 0 ]
		    then
			    Print_Output true "Entware NOT found, sleeping for $theSleepDelay secs [$sleepTimerSecs secs]..." "$WARN"
            fi
			sleep "$theSleepDelay"
            sleepTimerSecs="$((sleepTimerSecs + theSleepDelay))"
		done
		if [ ! -f /opt/bin/opkg ]
		then
			if "$doExitNotFound"
			then
			    Print_Output true "Entware NOT found and is required for $SCRIPT_NAME to run, please resolve." "$CRIT"
			    Clear_Lock ; exit 1
			else
			    Print_Output true "Entware NOT found. Starting $SCRIPT_NAME with extremely limited functionality." "$ERR"
			    Clear_Lock ; return 1
			fi
		else
			Print_Output true "Entware found, $SCRIPT_NAME will now continue" "$PASS"
			Clear_Lock
		fi
	fi
	return 0
}
### ###

Show_About()
{
	cat <<EOF
About
  $SCRIPT_NAME provides a graphical representation of domain
  blocking performed by Diversion.
License
  $SCRIPT_NAME is free to use under the GNU General Public License
  version 3 (GPL-3.0) https://opensource.org/licenses/GPL-3.0
Help & Support
  https://www.snbforums.com/forums/asuswrt-merlin-addons.60/?prefix_id=15
Source code
  https://github.com/jackyaz/$SCRIPT_NAME
EOF
	printf "\n"
}
### ###

### function based on @dave14305's FlexQoS show_help function ###
Show_Help()
{
	cat <<EOF
Available commands:
  $SCRIPT_NAME about              explains functionality
  $SCRIPT_NAME update             checks for updates
  $SCRIPT_NAME forceupdate        updates to latest version (force update)
  $SCRIPT_NAME startup force      runs startup actions such as mount WebUI tab
  $SCRIPT_NAME install            installs script
  $SCRIPT_NAME uninstall          uninstalls script
  $SCRIPT_NAME generate           update daily statistics and charts
  $SCRIPT_NAME fullrefresh        update daily, weekly and monthly statistics and charts
  $SCRIPT_NAME querylog           retrieve last 5000 records to show in WebUI
  $SCRIPT_NAME flushtodb          flush contents of cache to database
  $SCRIPT_NAME trimdb             run maintenance on database (this runs automatically every night)
  $SCRIPT_NAME enableprocs        re-enable background processing of Diversion statistics
  $SCRIPT_NAME disableprocs       disable background processing of Diversion statistics
  $SCRIPT_NAME develop            switch to development branch
  $SCRIPT_NAME stable             switch to stable branch
EOF
	printf "\n"
}
### ###

##-------------------------------------##
## Added by Martinski W. [2024-Nov-01] ##
##-------------------------------------##
TMPDIR="$SHARE_TEMP_DIR"
SQLITE_TMPDIR="$TMPDIR"
export SQLITE_TMPDIR TMPDIR

dbBackgProcsEnabled="$(_ToggleBackgroundProcsEnabled_ check)"

##----------------------------------------##
## Modified by Martinski W. [2024-Dec-13] ##
##----------------------------------------##
if [ $# -eq 0 ] || [ -z "$1" ]
then
	Create_Dirs
	Conf_Exists
	Create_Symlinks
	NTP_Ready
	Entware_Ready "$dbBackgProcsEnabled"

	if [ -f "$SCRIPT_DIR/SQLData.js" ] && [ -d "$SCRIPT_USB_DIR" ]
    then
		mv "$SCRIPT_DIR/SQLData.js" "$SCRIPT_USB_DIR/SQLData.js"
	fi
	"$dbBackgProcsEnabled" && Process_Upgrade
	Auto_Startup create 2>/dev/null
	Auto_DNSMASQ_Postconf create 2>/dev/null
	"$dbBackgProcsEnabled" && Auto_Cron create 2>/dev/null
	Auto_ServiceEvent create 2>/dev/null
	Shortcut_Script create
	ScriptHeader
	MainMenu
	exit 0
fi

##----------------------------------------##
## Modified by Martinski W. [2024-Dec-13] ##
##----------------------------------------##
case "$1" in
	install)
		Check_Lock
		Menu_Install
		exit 0
	;;
	startup)
		Menu_Startup "$2"
		exit 0
	;;
	generate)
		NTP_Ready
		Entware_Ready
		Check_Lock
		Menu_GenerateStats
		exit 0
	;;
	fullrefresh)
		NTP_Ready
		Entware_Ready
		Check_Lock
		Menu_GenerateStats fullrefresh
		exit 0
	;;
	service_event)
		if [ "$2" = "start" ] && [ "$3" = "$SCRIPT_NAME" ]; then
			rm -f /tmp/detect_uidivstats.js
			Check_Lock webui
			Menu_GenerateStats
			exit 0
		elif [ "$2" = "start" ] && [ "$3" = "${SCRIPT_NAME}querylog" ]; then
			Generate_Query_Log
			exit 0
		elif [ "$2" = "start" ] && [ "$3" = "${SCRIPT_NAME}config" ]; then
			Conf_FromSettings
			exit 0
		elif [ "$2" = "start" ] && [ "$3" = "${SCRIPT_NAME}checkupdate" ]; then
			Update_Check
			exit 0
		elif [ "$2" = "start" ] && [ "$3" = "${SCRIPT_NAME}doupdate" ]; then
			Update_Version force unattended
			exit 0
		fi
		exit 0
	;;
	dnsmasq)
		if "$dbBackgProcsEnabled" && \
		   [ -x /opt/etc/init.d/S90taildns ] && \
		   grep -q '^log-facility=/.*' /etc/dnsmasq.conf
		then
			Print_Output true "dnsmasq has restarted, restarting taildns" "$PASS"
			/opt/etc/init.d/S90taildns stop >/dev/null 2>&1
			sleep 3
			/opt/etc/init.d/S90taildns start >/dev/null 2>&1
		fi
		exit 0
	;;
	querylog)
		NTP_Ready
		Entware_Ready
		Generate_Query_Log
		exit 0
	;;
	flushtodb)
		NTP_Ready
		Entware_Ready
		Flush_Cache_To_DB
		exit 0
	;;
	trimdb)
		NTP_Ready
		Entware_Ready
		Trim_DNS_DB
		Check_Lock
		Migrate_Old_Data
		Optimise_DNS_DB
		Menu_GenerateStats fullrefresh
		exit 0
	;;
	enableprocs)
		Check_Lock
		_ToggleBackgroundProcsEnabled_ enable
		Clear_Lock
		exit 0
	;;
	disableprocs)
		Check_Lock
		_ToggleBackgroundProcsEnabled_ disable
		Clear_Lock
		exit 0
	;;
	update)
		Update_Version unattended
		exit 0
	;;
	forceupdate)
		Update_Version force unattended
		exit 0
	;;
	setversion)
		Set_Version_Custom_Settings local "$SCRIPT_VERSION"
		Set_Version_Custom_Settings server "$SCRIPT_VERSION"
		if [ -f "$SCRIPT_DIR/SQLData.js" ]; then
			mv "$SCRIPT_DIR/SQLData.js" "$SCRIPT_USB_DIR/SQLData.js"
		fi
		if [ -z "$2" ]; then
			exec "$0"
		fi
		exit 0
	;;
	postupdate)
		Create_Dirs
		if [ -f "$SCRIPT_DIR/SQLData.js" ]; then
			mv "$SCRIPT_DIR/SQLData.js" "$SCRIPT_USB_DIR/SQLData.js"
		fi
		Conf_Exists
		Create_Symlinks
		Process_Upgrade
		Auto_Startup create 2>/dev/null
		Auto_DNSMASQ_Postconf create 2>/dev/null
		Auto_Cron create 2>/dev/null
		Auto_ServiceEvent create 2>/dev/null
		Shortcut_Script create
	;;
	about)
		ScriptHeader
		Show_About
		exit 0
	;;
	help)
		ScriptHeader
		Show_Help
		exit 0
	;;
	uninstall)
		Menu_Uninstall
		exit 0
	;;
	develop)
		if false  ## The "develop" branch is NOT supported on this repository ##
		then
		    SCRIPT_BRANCH="develop"
		else
		    SCRIPT_BRANCH="master"
		    printf "\n${REDct}The 'develop' branch is NOT available. Updating from the 'master' branch...${CLEARct}\n"
		fi
		SCRIPT_REPO="https://raw.githubusercontent.com/decoderman/$SCRIPT_NAME/$SCRIPT_BRANCH"
		Update_Version force
		exit 0
	;;
	stable)
		SCRIPT_BRANCH="master"
		SCRIPT_REPO="https://raw.githubusercontent.com/decoderman/$SCRIPT_NAME/$SCRIPT_BRANCH"
		Update_Version force
		exit 0
	;;
	*)
		ScriptHeader
		Print_Output false "Command not recognised." "$ERR"
		Print_Output false "For a list of available commands run: $SCRIPT_NAME help" "$SETTING"
		exit 1
	;;
esac
