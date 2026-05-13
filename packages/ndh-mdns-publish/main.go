// ndh-mdns-publish — publish an arbitrary <name>.local A record via mDNS.
//
// Used by the Darwin and NixOS headscale-daemon modules to advertise a
// fleet-scoped alias (e.g. `headscale.mammoth-skate.local`) pointing at
// whichever host currently owns the headscale control-plane.  Exactly
// one host should run this at a time; the binary is long-lived and sends
// a goodbye packet on SIGTERM so clients drop the record promptly.
//
// Usage:
//
//	ndh-mdns-publish \
//	  --name=headscale.mammoth-skate \
//	  --port=41841 \
//	  [--ip=auto] \
//	  [--ttl=120s] \
//	  [--iface=en0]
//
// `--name` must NOT include `.local` — the mDNS stack appends it.  `--ip`
// defaults to the first non-loopback IPv4 address on the primary route;
// callers that want a specific address (e.g. pinning to a bridge) pass
// it explicitly.
package main

import (
	"flag"
	"fmt"
	"log"
	"net"
	"os"
	"os/signal"
	"strings"
	"syscall"
	"time"

	"github.com/hashicorp/mdns"
)

func main() {
	var (
		name       = flag.String("name", "", "instance name (without .local suffix); required")
		port       = flag.Int("port", 0, "TCP service port to advertise; required")
		host       = flag.String("host", "", "host portion of the FQDN to advertise (without .local); defaults to --name")
		ip         = flag.String("ip", "auto", "IP address to advertise; 'auto' picks the first non-loopback IPv4")
		iface      = flag.String("iface", "", "interface name to bind the mDNS responder on (default: all interfaces)")
		ttl        = flag.Duration("ttl", 120*time.Second, "record TTL")
		service    = flag.String("service", "_headscale-bootstrap._tcp", "DNS-SD service type to register under")
		domain     = flag.String("domain", "local.", "mDNS domain; must end with a dot")
		goodbyeWin = flag.Duration("goodbye-wait", 250*time.Millisecond, "delay after goodbye packet before exit")
	)
	flag.Parse()

	if *name == "" || *port == 0 {
		flag.Usage()
		os.Exit(2)
	}
	if !strings.HasSuffix(*domain, ".") {
		*domain = *domain + "."
	}
	if *host == "" {
		*host = *name
	}

	ipAddr, err := resolveIP(*ip)
	if err != nil {
		log.Fatalf("resolving --ip=%s: %v", *ip, err)
	}

	// hashicorp/mdns requires a fully-qualified hostname (trailing dot).
	// `*domain` is normalised above to always end in ".".
	hostFqdn := *host + "." + *domain

	info := []string{fmt.Sprintf("ndh-mdns-publish=%s", *name)}
	svc, err := mdns.NewMDNSService(
		*name,
		*service,
		*domain,
		hostFqdn,
		*port,
		[]net.IP{ipAddr},
		info,
	)
	if err != nil {
		log.Fatalf("constructing mdns service: %v", err)
	}

	cfg := &mdns.Config{Zone: svc}
	if *iface != "" {
		nif, err := net.InterfaceByName(*iface)
		if err != nil {
			log.Fatalf("looking up iface %q: %v", *iface, err)
		}
		cfg.Iface = nif
	}

	server, err := mdns.NewServer(cfg)
	if err != nil {
		log.Fatalf("starting mdns server: %v", err)
	}
	defer server.Shutdown()

	// MDNSService uses a fixed TTL; log the requested value so the
	// operator sees what the binary understood.  (hashicorp/mdns does
	// not expose a public TTL setter.)
	log.Printf("advertising %s %s:%d on %s (ttl=%s)",
		strings.TrimSuffix(hostFqdn, "."), ipAddr, *port,
		coalesce(*iface, "all interfaces"), ttl)

	sig := make(chan os.Signal, 1)
	signal.Notify(sig, syscall.SIGINT, syscall.SIGTERM)
	<-sig

	// `server.Shutdown()` in defer emits a goodbye packet; give the
	// network a brief window to drain it before the process exits so
	// clients see the TTL=0 advertisement and drop the cache entry.
	log.Printf("shutdown: sending goodbye, waiting %s", *goodbyeWin)
	time.Sleep(*goodbyeWin)
}

// resolveIP turns an `--ip` flag value into a net.IP.  `"auto"` picks
// the first non-loopback IPv4 address by walking live interfaces.
func resolveIP(s string) (net.IP, error) {
	if s != "auto" {
		ip := net.ParseIP(s)
		if ip == nil {
			return nil, fmt.Errorf("not a valid IP: %q", s)
		}
		return ip, nil
	}

	ifaces, err := net.Interfaces()
	if err != nil {
		return nil, err
	}
	for _, ifi := range ifaces {
		if ifi.Flags&net.FlagUp == 0 || ifi.Flags&net.FlagLoopback != 0 {
			continue
		}
		addrs, err := ifi.Addrs()
		if err != nil {
			continue
		}
		for _, a := range addrs {
			var ip net.IP
			switch v := a.(type) {
			case *net.IPNet:
				ip = v.IP
			case *net.IPAddr:
				ip = v.IP
			}
			if ip == nil || ip.IsLoopback() {
				continue
			}
			if v4 := ip.To4(); v4 != nil {
				return v4, nil
			}
		}
	}
	return nil, fmt.Errorf("no non-loopback IPv4 address found on any live interface")
}

func coalesce(a, b string) string {
	if a != "" {
		return a
	}
	return b
}
