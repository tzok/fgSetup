#!/bin/bash
#
# FutureGateway APIServerDaemon apt-get version setup script
#
# Author: Riccardo Bruno <riccardo.bruno@ct.infn.it>
#

source .fgprofile/commons
source .fgprofile/apt_commons
source .fgprofile/config

FGLOG=$HOME/APIServerDaemon.log
ASDB_OPTS="-sN"

# The array above contains any global scope temporaty file
TEMP_FILES=() 

# Create temporary files
cleanup_tempFiles() {
  echo "Cleaning temporary files:"
  for tempfile in ${TEMP_FILES[@]}
  do
    #echo "Viewing '"$tempfile"':"
    #cat $tempfile
    printf "Cleaning up '"$tempfile"' ... "
    rm -rf $tempfile
    echo "done"
  done
}

#
# Script body
#

# Cleanup global scope temporary files upon exit
trap cleanup_tempFiles EXIT

# Local temporary files for SSH output and error files
STD_OUT=$(mktemp -t stdout.XXXXXX)
STD_ERR=$(mktemp -t stderr.XXXXXX)
TEMP_FILES+=( $STD_OUT )
TEMP_FILES+=( $STD_ERR )
CMD_FILE=$(mktemp -t command.XXXXXX)
CMD_OUT=$(mktemp -t stdout.XXXXXX)
CMD_ERR=$(mktemp -t stderr.XXXXXX)
TEMP_FILES+=( $CMD_FILE )
TEMP_FILES+=( $CMD_OUT )
TEMP_FILES+=( $CMD_ERR )

out "Starting FutureGateway APIServerDaemon apt-get versioned setup script"

# Check for FutureGateway fgAPIServer unix user
check_and_create_user $FGAPISERVER_APPHOSTUNAME

# Mandatory packages installation
out "Installing packages ..." 1
# Mandatory packages installation
APTPACKAGES=(
  curl
  git
  wget
  coreutils
  jq
  mysql-client
  ant
  maven
  tomcat7
  openjdk-7-jdk
)
CMD="install_apt ${APTPACKAGES[@]}"
exec_cmd "Error installing required packages"

#
# Checking packages consistency
#

# Check mandatory command line commands
out "Verifying mandatory commands ... " 1
CMD="MISSING_PKGS=\"\"; \
     GIT=\$(which git || \$MISSING_PKGS=\$MISSING_PKGS\"git \"); \
     ANT=\$(which ant || \$MISSING_PKGS=\$MISSING_PKGS\"ant \"); \
     MVN=\$(which mvn || \$MISSING_PKGS=\$MISSING_PKGS\"mvn \"); \
     CATALINA=\$(ls -1 /etc/init.d | grep tomcat || \$MISSING_PKGS=\$MISSING_PKGS\"tomcat \"); \
     JAVA=\$(which java || \$MISSING_PKGS=$MISSING_PKGS\"java \"); \
     [ \"\$MISSING_PKGS\" == \"\" ] || echo  \"Missing packages identified: \$MISSING_PKGS\""
exec_cmd "Following mandatory commands are not present: \"$MISSING_PKGS\"" "(git: \$GIT, ant: \$ANT, mvn: \$MVN, tomcat: \$CATALINA, java: \$JAVA)"

# Check Java v >= 1.6.0
CMD="JAVA_VER=\$(java -version 2>&1|\
                 grep version |\
                 awk '{ print \$3 }' |\
                 xargs echo |\
                 awk -F\"_\" '{ print \$1 }' |\
                 tr -d '.'); [ \"\$JAVA_VER\" -gt 160 ]"
exec_cmd "Unsupported java version; (>= 1.6.0)" "(java version: \$JAVA_VER)" "(java version: \$JAVA_VER)" 

# Check and configure catalina (Tomcat)
export CATALINA_HOME=$(cat /etc/init.d/$CATALINA |\
                       grep ^CATALINA_HOME |\
                       awk -F'=' '{ print $2}' |\
                       sed s/\$NAME/$CATALINA/ |\
                       xargs echo)
export CATALINA_BASE=$(cat /etc/init.d/$CATALINA |\
                       grep ^CATALINA_BASE |\
                       awk -F'=' '{ print $2}' |\
                       sed s/\$NAME/$CATALINA/ |\
                       xargs echo)
out "CATALINA_HOME=$CATALINA_HOME"
out "CATALINA_BASE=$CATALINA_BASE"

CMD="[ \"\$CATALINA_HOME\" != \"\" -a \"\$CATALINA_BASE\" != \"\" ]"
exec_cmd "Did not find Tomcat environment variables CATALINA_HOME or CATALINA_BASE"

cat >$CMD_FILE <<EOF
sudo updatedb &&\
TOMCAT_USRFILE=\$(locate tomcat-users.xml | head -n 1) &&\
sudo cp \$TOMCAT_USRFILE \${TOMCAT_USRFILE}_orig &&\
LN=\$(cat \${TOMCAT_USRFILE}_orig | grep -n "</tomcat-users>" | awk -F":" '{ print \$1 }') &&\
ALN=\$(cat \${TOMCAT_USRFILE}_orig | wc -l) &&\
sudo cat \${TOMCAT_USRFILE}_orig | head -n \$((LN-1)) > \$TOMCAT_USRFILE &&\
sudo echo "                 <role rolename=\"manager-gui\"/>" >> \$TOMCAT_USRFILE &&\
sudo echo "                 <role rolename=\"manager-script\"/>" >> \$TOMCAT_USRFILE &&\
sudo echo "                 <role rolename=\"tomcat\"/>" >> \$TOMCAT_USRFILE &&\
sudo echo "                 <role rolename=\"liferay\"/>" >> \$TOMCAT_USRFILE &&\
sudo echo "                 <user username=\"$TOMCAT_USER\" password=\"$TOMCAT_PASSWORD\" roles=\"tomcat,liferay,manager-gui,manager-script\"/>" >> \$TOMCAT_USRFILE &&\
sudo cat \${TOMCAT_USRFILE}_orig | tail -n \$((ALN-LN+1)) >> \$TOMCAT_USRFILE
EOF
CMD=$(cat $CMD_FILE)
exec_cmd "Unable to configure tomcat user roles"

out "Setup mysql-connector" 1
CMD="sudo updatedb &&\
     MYSQL_CONNECTOR=\$(locate mysql-connector-java.jar) &&\
     cd \$CATALINA_HOME/lib &&\
     sudo ln -s \$MYSQL_CONNECTOR mysql-connector-java.jar &&\
     [ -L  \$MYSQL_CONNECTOR mysql-connector-java.jar ]"
exec_cmd "Unable to setup mysql-connector" "(\$MYSQL_CONNECTOR)"

out " Configuring GridEngine connection pools" 1
cat >$CMD_FILE <<EOF
sudo chmod 644 $CATALINA_HOME/conf/server.xml &&\
sudo chmod g+x /usr/local/tomcat/conf &&\
sudo cp $CATALINA_HOME/conf/server.xml $CATALINA_HOME/conf/server.xml_orig &&\
LN=\$(cat $CATALINA_HOME/conf/server.xml_orig | grep -n "</GlobalNamingResources>" | awk -F":" '{ print $1 }') &&\
ALN=\$(cat $CATALINA_HOME/conf/server.xml_orig | wc -l) &&\
sudo cat $CATALINA_HOME/conf/server.xml_orig | head -n \$((LN-1)) > $CATALINA_HOME/conf/server.xml &&\
sudo echo "               <Resource name=\"jdbc/UserTrackingPool\"" >> $CATALINA_HOME/conf/server.xml &&\
sudo echo "                           auth=\"Container\"" >> $CATALINA_HOME/conf/server.xml &&\
sudo echo "                           type=\"javax.sql.DataSource\"" >> $CATALINA_HOME/conf/server.xml &&\
sudo echo "                           username=\"$UTDB_USER\"" >> $CATALINA_HOME/conf/server.xml &&\
sudo echo "                           password=\"$UTDB_PASSWORD\"" >> $CATALINA_HOME/conf/server.xml &&\
sudo echo "                           driverClassName=\"com.mysql.jdbc.Driver\"" >> $CATALINA_HOME/conf/server.xml &&\
sudo echo "                           url=\"jdbc:mysql://$UTDB_HOST:$UTDB_PORT/$UTDB_DATABASE\"" >> $CATALINA_HOME/conf/server.xml &&\
sudo echo "                           testOnBorrow=\"true\"" >> $CATALINA_HOME/conf/server.xml &&\
sudo echo "                           testWhileIdle=\"true\"" >> $CATALINA_HOME/conf/server.xml &&\
sudo echo "                           validationInterval=\"0\"" >> $CATALINA_HOME/conf/server.xml &&\
sudo echo "                           initialSize=\"3\"" >> $CATALINA_HOME/conf/server.xml &&\
sudo echo "                           maxTotal=\"100\"" >> $CATALINA_HOME/conf/server.xml &&\
sudo echo "                           maxIdle=\"30\"" >> $CATALINA_HOME/conf/server.xml &&\
sudo echo "                           maxWaitMillis=\"10000\"/>" >> $CATALINA_HOME/conf/server.xml &&\
sudo echo "                 <Resource name=\"jdbc/gehibernatepool\"" >> $CATALINA_HOME/conf/server.xml &&\
sudo echo "                           auth=\"Container\"" >> $CATALINA_HOME/conf/server.xml &&\
sudo echo "                           type=\"javax.sql.DataSource\"" >> $CATALINA_HOME/conf/server.xml &&\
sudo echo "                           username=\"$UTDB_USER\"" >> $CATALINA_HOME/conf/server.xml &&\
sudo echo "                           password=\"$UTDB_PASSWORD\"" >> $CATALINA_HOME/conf/server.xml &&\
sudo echo "                           driverClassName=\"com.mysql.jdbc.Driver\"" >> $CATALINA_HOME/conf/server.xml &&\
sudo echo "                           url=\"jdbc:mysql://$UTDB_HOST:$UTDB_PORT/$UTDB_DATABASE\"" >> $CATALINA_HOME/conf/server.xml &&\
sudo echo "                           testOnBorrow=\"true\"" >> $CATALINA_HOME/conf/server.xml &&\
sudo echo "                           testWhileIdle=\"true\"" >> $CATALINA_HOME/conf/server.xml &&\
sudo echo "                           validationInterval=\"0\"" >> $CATALINA_HOME/conf/server.xml &&\
sudo echo "                           initialSize=\"3\"" >> $CATALINA_HOME/conf/server.xml &&\
sudo echo "                           maxTotal=\"100\"" >> $CATALINA_HOME/conf/server.xml &&\
sudo echo "                           maxIdle=\"30\"" >> $CATALINA_HOME/conf/server.xml &&\
sudo echo "                           maxWaitMillis=\"10000\"/>" >> $CATALINA_HOME/conf/server.xml &&\
sudo cat $CATALINA_HOME/conf/server.xml_orig | tail -n \$((ALN-LN+1)) >> $CATALINA_HOME/conf/server.xml
EOF
CMD=$(cat $CMD_FILE)
exec_cmd "Unable to setup UserTracking connection pools"

# It seems a missing directory exists
sudo mkdir -p /usr/share/tomcat7/logs
sudo mkdir -p /usr/share/tomcat7/common/classes
sudo mkdir -p /usr/share/tomcat7/server/classes
sudo mkdir -p /usr/share/tomcat7/shared/classes
sudo chown -R tomcat7.tomcat7 /var/log/tomcat7
sudo chown -R tomcat7.tomcat7 /var/lib/tomcat7/logs

# Do not use service since containers may not accept this way
# Starting Tomcat using startup script
out "Executing $CATALINA service ... " 1
TOMCATP=$(ps -ef | grep $CATALINA | grep -v grep | awk '{ print $2 }')
if [ "$TOMCATP" != "" ]; then
  out "Service $CATALINA executing with process: $TOMCATP"
else
  out "Starting $CATALINA ..." 1
  CMD="$CATALINA_HOME/bin/catalina.sh start"
  exec_cmd "Unable to start service $CATALINA"\
           "($CATALINA: \$(ps -ef | grep \$CATALINA | grep -v grep | awk '{ print \$2 }')"
fi
    
# Check mysql client
out "Looking up mysql client ... " 1
CMD="MYSQL=\$(which mysql)"
exec_cmd "Did not find mysql command" "(\$MYSQL)"

# Check mysql version
out "Looking up mysql version ... " 1
CMD="MYSQLVER=\$(\$MYSQL -V | awk '{ print \$5 }' | awk -F \".\" '{ v=\$1*10+\$2; printf (\"%s\",v) }')"
exec_cmd "Did not retrieve mysql version" "(\$MYSQLVER)"

#Check connectivity
out "Checking mysql connectivity ... " 1
CMD="$MYSQL -h $FGDB_HOST -P $FGDB_PORT -u root $([ \"$FGDB_ROOTPWD\" != \"\" ] && echo \"-p$FGDB_ROOTPWD\") -e \"select version()\" >$CMD_OUT 2>$CMD_ERR"
exec_cmd "Missing mysql connectivity"

#
# Software packages setup
#

out "Extracting/installing software ..."

# JSAGA
# PortalSetup used to install jsaga and its libraries accordingly to the instructions
# reported on its download page: http://software.in2p3.fr/jsaga/latest-release/download.html
# Actually the new recommended way to install it is via maven configuring the java project.
# This installation will perform the new suggested way as reported at:
# https://indigo-dc.gitbooks.io/jsaga-resource-management/content/deployment.html

# OCCI+(GSI)
OCCI=$(which occi)
if [ "$OCCI" != "" -a -d /etc/grid-security/vomsdir -a -d /etc/vomses/ ]; then
    out "WARNING: Most probably OCCI client and GSI are already installed; skipping their installation"
else
    curl -L http://go.egi.eu/fedcloud.ui | sudo /bin/bash -

    # Now configure VO fedcloud.egi.eu
    sudo mkdir -p /etc/grid-security/vomsdir/fedcloud.egi.eu

    sudo chmod o+w /etc/grid-security/vomsdir/fedcloud.egi.eu
    sudo cat > /etc/grid-security/vomsdir/fedcloud.egi.eu/voms1.egee.cesnet.cz.lsc << EOF 
/DC=org/DC=terena/DC=tcs/OU=Domain Control Validated/CN=voms1.egee.cesnet.cz
/C=NL/O=TERENA/CN=TERENA eScience SSL CA
EOF
    sudo cat > /etc/grid-security/vomsdir/fedcloud.egi.eu/voms2.grid.cesnet.cz << EOF 
/DC=org/DC=terena/DC=tcs/C=CZ/ST=Hlavni mesto Praha/L=Praha 6/O=CESNET/CN=voms2.grid.cesnet.cz
/C=NL/ST=Noord-Holland/L=Amsterdam/O=TERENA/CN=TERENA eScience SSL CA 3
EOF
    sudo chmod o-w /etc/grid-security/vomsdir/fedcloud.egi.eu

    sudo mkdir -p /etc/vomses
    sudo chmod o+w /etc/vomses
    sudo cat >> /etc/vomses/fedcloud.egi.eu << EOF 
"fedcloud.egi.eu" "voms1.egee.cesnet.cz" "15002" "/DC=org/DC=terena/DC=tcs/OU=Domain Control Validated/CN=voms1.egee.cesnet.cz" "fedcloud.egi.eu" "24"
"fedcloud.egi.eu" "voms2.grid.cesnet.cz" "15002" "/DC=org/DC=terena/DC=tcs/C=CZ/ST=Hlavni mesto Praha/L=Praha 6/O=CESNET/CN=voms2.grid.cesnet.cz" "fedcloud.egi.eu" "24"
EOF
    sudo chmod o-w /etc/vomses
fi

# It seems OCCI generates wrong entries in sources.list.d
rm -f /etc/apt/sources.list.d/UMD-3-*.list

# Getting or updading software from Git
MISSING_GITREPO=""
CMD="MISSING_GITREPO=\"\";\
     git_clone_or_update \"\$GNCENG_GIT_BASE\" \"\$GNCENG_GITREPO\" \"\$GNCENG_GITTAG\" ||\
     MISSING_GITREPO=\$MISSING_GITREPO\"\$GNCENG_GITREPO \";\
     git_clone_or_update \"\$ROCCI_GIT_BASE\" \"\$ROCCI_GITREPO\" \"\$ROCCI_GITTAG\" ||\
     MISSING_GITREPO=\$MISSING_GITREPO\"$ROCCI_GITREPO \";\
     git_clone_or_update \"\$GIT_BASE\" \"\$APISERVERDAEMON_GITREPO\" \"$APISERVERDAEMON_GITTAG\" ||\
     MISSING_GITREPO=\$MISSING_GITREPO\"\$APISERVERDAEMON_GITREPO \";\
     [ "$MISSING_GITREPO" == "" ]"
exec_cmd "Following Git repositories failed to clone/update: \"$MISSING_GITREPO\"" "" "missing repositories: \"$MISSING_GITREPO\""

#
# Compiling APIServerDaemon components and executor interfaces
#
out "Starting APIServerDaemon components compilation ... "

# Creting lib/ directory under APIServerDaemon dir
mkdir -p $APISERVERDAEMON_GITREPO/lib
mkdir -p $APISERVERDAEMON_GITREPO/web/WEB-INF/lib

# Compile EI components and APIServerDaemon
MISSING_COMPILATION=""

# rOCCI jsaga adaptor for Grid and Cloud Engine
cd $ROCCI_GITREPO
ant all || MISSING_COMPILATION=$MISSING_COMPILATION"$ROCCI_GITREPO "
[ -f dist/$ROCCI_GITREPO.jar ] && cp dist/$ROCCI_GITREPO.jar ../$APISERVERDAEMON_GITREPO/lib/
cd - 2>&1 >/dev/null

# Grid and Cloud Engine
cd $GNCENG_GITREPO/grid-and-cloud-engine-threadpool
mvn install || MISSING_COMPILATION=$MISSING_COMPILATION"$GNCENG_GITREPO "
GNCENG_THREADPOOL_LIB=$(find . -name '*.jar' | grep grid-and-cloud-engine-threadpool)
[ -f $GNCENG_THREADPOOL_LIB ] && cp $GNCENG_THREADPOOL_LIB ../../$APISERVERDAEMON_GITREPO/lib/
cd - 2>&1 >/dev/null
cd $GNCENG_GITREPO/grid-and-cloud-engine_M
mvn install || MISSING_COMPILATION=$MISSING_COMPILATION"$GNCENG_GITREPO "
GNCENG_GNCENG_LIB=$(find . -name '*.jar' | grep grid-and-cloud-engine_M)
[ -f $GNCENG_GNCENG_LIB ] && cp $GNCENG_GNCENG_LIB ../../$APISERVERDAEMON_GITREPO/lib/
cd - 2>&1 >/dev/null

cd $APISERVERDAEMON_GITREPO
# APIServerDaemon.properties
PROPF=./web/WEB-INF/classes/it/infn/ct/APIServerDaemon.properties
replace_line $PROPF "apisrv_dbhost" "apisrv_dbhost = $FGDB_HOST"
replace_line $PROPF "apisrv_dbport" "apisrv_dbport = $FGDB_PORT"
replace_line $PROPF "apisrv_dbuser" "apisrv_dbuser = $FGDB_USER"
replace_line $PROPF "apisrv_dbuser" "apisrv_dbuser = $FGDB_USER"
replace_line $PROPF "apisrv_dbpass" "apisrv_dbpass = $FGDB_PASS"
replace_line $PROPF "apisrv_dbname" "apisrv_dbname = $FGDB_NAME"
replace_line $PROPF "apisrv_dbver" "apisrv_dbver = $ASDBVER"
replace_line $PROPF "asdMaxThreads" "asdMaxThreads = $APISERVERDAEMON_MAXTHREADS"
replace_line $PROPF "asdCloseTimeout" "asdCloseTimeout = $APISERVERDAEMON_ASDCLOSETIMEOUT"
replace_line $PROPF "gePollingDelay" "gePollingDelay = $APISERVERDAEMON_GEPOLLINGDELAY"
replace_line $PROPF "gePollingMaxCommands" "gePollingMaxCommands = $APISERVERDAEMON_GEPOLLINGMAXCOMMANDS"
replace_line $PROPF "asControllerDelay" "asControllerDelay = $APISERVERDAEMON_ASCONTROLLERDELAY"
replace_line $PROPF "asControllerMaxCommands" "asControllerMaxCommands = $APISERVERDAEMON_ASCONTROLLERMAXCOMMANDS"
replace_line $PROPF "asTaskMaxRetries" "asTaskMaxRetries = $APISERVERDAEMON_ASTASKMAXRETRIES"
replace_line $PROPF "asTaskMaxWait" "asTaskMaxWait = $APISERVERDAEMON_ASTASKMAXWAIT"
replace_line $PROPF "utdb_jndi" "utdb_jndi = $APISERVERDAEMON_UTDB_JNDI"
replace_line $PROPF "utdb_host" "utdb_host = $APISERVERDAEMON_UTDB_HOST"
replace_line $PROPF "utdb_port" "utdb_port = $APISERVERDAEMON_UTDB_PORT"
replace_line $PROPF "utdb_user" "utdb_user = $APISERVERDAEMON_UTDB_USER"
replace_line $PROPF "utdb_pass" "utdb_pass = $APISERVERDAEMON_UTDB_PASS"
replace_line $PROPF "utdb_name" "utdb_name = $APISERVERDAEMON_UTDB_NAME"
# ToscaIDC.properties
PROPF=./web/WEB-INF/classes/it/infn/ct/ToscaIDC.properties
replace_line $PROPF "fgapisrv_ptvtokensrv" "fgapisrv_ptvendpoint = $TOSCAIDC_FGAPISRV_PTVENDPOINT/get-token/"
replace_line $PROPF "fgapisrv_ptvuser" "fgapisrv_ptvuser = $TOSCAIDC_FGAPISRV_PTVUSER"
replace_line $PROPF "fgapisrv_ptvpass" "fgapisrv_ptvpass = $TOSCAIDC_FGAPISRV_PTVPASS"
cd - 2>/dev/null >/dev/null
out "done" 0 1

# APIServerDaemon
cd $APISERVERDAEMON_GITREPO
ant all || MISSING_COMPILATION=$MISSING_COMPILATION"$APISERVERDAEMON_GITREPO "
[ -f dist/APIServerDaemon.war/$APISERVERDAEMON_GITREPO.war ] && cp dist/APIServerDaemon.war/$APISERVERDAEMON_GITREPO.war $CATALINA_HOME/webapps
cd - 2>&1 >/dev/null
if [ "$MISSING_COMPILATION" != "" ]; then
  out "ERROR: Following components did not compile successfully: \"$MISSING_COMPILATION\""
  exit 1
fi

out "Successfully compiled all APIServerDaemon components"


# Environment setup
out "Preparing the environment ..."
   
# Now take care of environment settings
out "Setting up \"$APISERVERDAEMON_HOSTUNAME\" user profile ..."
   
# Preparing user environment in .fgprofile/APIServerDaemon file
#   BGDB variables
#   DB macro functions
FGAPISERVERENVFILEPATH=.fgprofile/APIServerDaemon
cat >$FGAPISERVERENVFILEPATH <<EOF
#!/bin/bash
#
# APIServerDaemon Environment setting configuration file
#
# Very specific APIServerDaemon service components environment must be set here
#
# Author: Riccardo Bruno <riccardo.bruno@ct.infn.it>
EOF
#for vgdbvar in ${FGAPISERVER_VARS[@]}; do
#    echo "$vgdbvar=${!vgdbvar}" >> $FGAPISERVERENVFILEPATH
#done
## Now place functions from setup_commons.sh
#declare -f asdb  >> $FGAPISERVERENVFILEPATH
#declare -f asdbr >> $FGAPISERVERENVFILEPATH
#declare -f dbcn  >> $FGAPISERVERENVFILEPATH
#out "done" 0 1
out "User profile successfully created"
   


out "Successfully finished FutureGateway APIServerDaemon brew versioned setup script"
exit $RES

