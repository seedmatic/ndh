source @nixBashTrampoline@

main() {
	set -e
	echo "Starting BIRD configuration..."
	umask u=rwx,g=rx,o=rx
	echo "Umask set to $(umask)"
	echo "Creating BIRD user and group..."
	@createUserScript@/bin/create-daemon-user --user @user@ --group @group@
	echo "Creating BIRD run directory..."
	mkdir -p /var/run/bird
	chown -R @user@:@group@ /var/run/bird
	echo "Creating and setting permissions for log files..."
	touch /var/log/bird.log /var/log/bird.error.log
	chown @user@:@group@ /var/log/bird.log /var/log/bird.error.log
	chmod 644 /var/log/bird.log /var/log/bird.error.log
	echo "Listing contents of /etc/bird:"
	ls -alR /etc/bird
	echo "BIRD configuration completed"

	echo "Loading re-defined pf rules"
	pfctl -nf /etc/pf.anchors/org.bird.daemon
	pfctl -a org.bird.daemon -f /etc/pf.anchors/org.bird.daemon

	patch -u -N -t -b -l -p0 << 'EOF'
--- /etc/pf.conf.orig	2024-10-16 18:03:10.647408657 +0200
+++ /etc/pf.conf	2024-10-16 18:10:11.438461597 +0200
@@ -21,5 +21,7 @@
 #
 scrub-anchor "com.apple/*"
 nat-anchor "com.apple/*"
 rdr-anchor "com.apple/*"
 dummynet-anchor "com.apple/*"
+anchor "org.bird.daemon"
+load anchor "org.bird.daemon" from "/etc/pf.anchors/org.bird.daemon"
EOF
}

ndh::logger:command:run "@loggerTag@" main "$@"
