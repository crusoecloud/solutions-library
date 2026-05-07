package main

import (
	"bufio"
	"fmt"
	"io"
	"log"
	"net"
	"os"
	"os/signal"
	"strconv"
	"strings"
	"syscall"
	"time"

	"github.com/miekg/dns"
)

func main() {
	var hostnames []string
	for _, h := range strings.Split(os.Getenv("RESOLVE_HOSTNAME"), ",") {
		if h = strings.TrimSpace(h); h != "" {
			hostnames = append(hostnames, h)
		}
	}
	if len(hostnames) == 0 {
		log.Fatal("RESOLVE_HOSTNAME environment variable is required")
	}

	hostsFile := os.Getenv("HOSTS_FILE")
	if hostsFile == "" {
		hostsFile = "/etc/hosts"
	}

	interval := 5 * time.Second
	if s := os.Getenv("INTERVAL_SECONDS"); s != "" {
		n, err := strconv.Atoi(s)
		if err != nil || n < 1 {
			log.Fatalf("invalid INTERVAL_SECONDS %q: must be a positive integer", s)
		}
		interval = time.Duration(n) * time.Second
	}

	nameservers, err := resolveNameservers()
	if err != nil {
		log.Fatalf("failed to determine nameservers: %v", err)
	}

	log.Printf("starting: hostnames=%v file=%s interval=%s", hostnames, hostsFile, interval)

	sigCh := make(chan os.Signal, 1)
	signal.Notify(sigCh, syscall.SIGTERM, syscall.SIGINT)

	ticker := time.NewTicker(interval)
	defer ticker.Stop()

	updateAll := func() {
		for _, h := range hostnames {
			if err := updateHosts(nameservers, h, hostsFile); err != nil {
				log.Printf("error: %v", err)
			}
		}
	}

	// Run immediately on start rather than waiting for the first tick.
	updateAll()

	for {
		select {
		case <-ticker.C:
			updateAll()
		case sig := <-sigCh:
			log.Printf("received %s, cleaning up %s", sig, hostsFile)
			var failed bool
			for _, h := range hostnames {
				if err := cleanupHosts(h, hostsFile); err != nil {
					log.Printf("cleanup error: %v", err)
					failed = true
				}
			}
			if failed {
				os.Exit(1)
			}
			os.Exit(0)
		}
	}
}

// resolveNameservers returns nameservers from RESOLVERS env var (comma-delimited)
// or falls back to /etc/resolv.conf.
func resolveNameservers() ([]string, error) {
	if v := os.Getenv("RESOLVERS"); v != "" {
		var servers []string
		for _, s := range strings.Split(v, ",") {
			if s = strings.TrimSpace(s); s != "" {
				servers = append(servers, s)
			}
		}
		if len(servers) == 0 {
			return nil, fmt.Errorf("RESOLVERS is set but contains no valid entries")
		}
		log.Printf("using nameservers from RESOLVERS: %v", servers)
		return servers, nil
	}
	servers, err := nameserversFromResolvConf("/etc/resolv.conf")
	if err != nil {
		return nil, err
	}
	log.Printf("using nameservers from /etc/resolv.conf: %v", servers)
	return servers, nil
}

func nameserversFromResolvConf(path string) ([]string, error) {
	f, err := os.Open(path)
	if err != nil {
		return nil, fmt.Errorf("open %s: %w", path, err)
	}
	defer f.Close()

	var servers []string
	scanner := bufio.NewScanner(f)
	for scanner.Scan() {
		fields := strings.Fields(scanner.Text())
		if len(fields) >= 2 && fields[0] == "nameserver" {
			servers = append(servers, fields[1])
		}
	}
	if err := scanner.Err(); err != nil {
		return nil, fmt.Errorf("scan %s: %w", path, err)
	}
	if len(servers) == 0 {
		return nil, fmt.Errorf("no nameserver entries found in %s", path)
	}
	return servers, nil
}

// lookupAddresses queries nameservers directly via DNS, completely bypassing
// /etc/hosts. net.Resolver.LookupHost consults /etc/hosts before DNS regardless
// of any custom Dial func, which would make us read back our own stale entries.
func lookupAddresses(nameservers []string, hostname string) ([]string, error) {
	c := &dns.Client{Net: "udp", Timeout: 5 * time.Second}
	fqdn := dns.Fqdn(hostname)

	var addrs []string
	for _, qtype := range []uint16{dns.TypeA, dns.TypeAAAA} {
		results, err := queryDNS(c, nameservers, fqdn, qtype)
		if err != nil {
			return nil, fmt.Errorf("query %s: %w", dns.TypeToString[qtype], err)
		}
		addrs = append(addrs, results...)
	}

	if len(addrs) == 0 {
		return nil, fmt.Errorf("no A or AAAA records found for %s", hostname)
	}
	return addrs, nil
}

func queryDNS(c *dns.Client, nameservers []string, fqdn string, qtype uint16) ([]string, error) {
	m := new(dns.Msg)
	m.SetQuestion(fqdn, qtype)
	m.RecursionDesired = true

	var lastErr error
	for _, ns := range nameservers {
		r, _, err := c.Exchange(m, net.JoinHostPort(ns, "53"))
		if err != nil {
			lastErr = err
			continue
		}
		if r.Rcode != dns.RcodeSuccess && r.Rcode != dns.RcodeNameError {
			lastErr = fmt.Errorf("DNS error: %s", dns.RcodeToString[r.Rcode])
			continue
		}
		var addrs []string
		for _, ans := range r.Answer {
			switch rr := ans.(type) {
			case *dns.A:
				addrs = append(addrs, rr.A.String())
			case *dns.AAAA:
				addrs = append(addrs, rr.AAAA.String())
			}
		}
		return addrs, nil
	}
	return nil, lastErr
}

// stripBlock removes the managed block for hostname from content and returns
// the remaining lines with trailing blank lines trimmed.
func stripBlock(content, hostname string) []string {
	begin := fmt.Sprintf("# BEGIN etchosts-pin:%s", hostname)
	end := fmt.Sprintf("# END etchosts-pin:%s", hostname)

	lines := strings.Split(content, "\n")
	var kept []string
	inBlock := false
	for _, line := range lines {
		switch line {
		case begin:
			inBlock = true
		case end:
			inBlock = false
		default:
			if !inBlock {
				kept = append(kept, line)
			}
		}
	}
	for len(kept) > 0 && kept[len(kept)-1] == "" {
		kept = kept[:len(kept)-1]
	}
	return kept
}

func rewriteFile(f *os.File, content string) error {
	if _, err := f.WriteAt([]byte(content), 0); err != nil {
		return fmt.Errorf("write: %w", err)
	}
	if err := f.Truncate(int64(len(content))); err != nil {
		return fmt.Errorf("truncate: %w", err)
	}
	return nil
}

func updateHosts(nameservers []string, hostname, hostsFile string) error {
	addrs, err := lookupAddresses(nameservers, hostname)
	if err != nil {
		return fmt.Errorf("resolve %s: %w", hostname, err)
	}

	f, err := os.OpenFile(hostsFile, os.O_RDWR, 0644)
	if err != nil {
		return fmt.Errorf("open %s: %w", hostsFile, err)
	}
	defer f.Close()

	content, err := io.ReadAll(f)
	if err != nil {
		return fmt.Errorf("read %s: %w", hostsFile, err)
	}

	kept := stripBlock(string(content), hostname)

	block := []string{"", fmt.Sprintf("# BEGIN etchosts-pin:%s", hostname)}
	for _, addr := range addrs {
		block = append(block, fmt.Sprintf("%s\t%s", addr, hostname))
	}
	block = append(block, fmt.Sprintf("# END etchosts-pin:%s", hostname))

	if err := rewriteFile(f, strings.Join(append(kept, block...), "\n")+"\n"); err != nil {
		return fmt.Errorf("%s: %w", hostsFile, err)
	}

	log.Printf("updated %s → %v", hostname, addrs)
	return nil
}

func cleanupHosts(hostname, hostsFile string) error {
	f, err := os.OpenFile(hostsFile, os.O_RDWR, 0644)
	if err != nil {
		return fmt.Errorf("open %s: %w", hostsFile, err)
	}
	defer f.Close()

	content, err := io.ReadAll(f)
	if err != nil {
		return fmt.Errorf("read %s: %w", hostsFile, err)
	}

	kept := stripBlock(string(content), hostname)

	if err := rewriteFile(f, strings.Join(kept, "\n")+"\n"); err != nil {
		return fmt.Errorf("%s: %w", hostsFile, err)
	}

	log.Printf("removed entries for %s from %s", hostname, hostsFile)
	return nil
}
