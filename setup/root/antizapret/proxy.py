#!/usr/bin/env -S python3 -u
# -*- coding: utf-8 -*-

import subprocess,time,argparse,threading,copy,os
from ipaddress import IPv4Network,IPv6Network,ip_address,ip_network
from dnslib import DNSRecord,RCODE,QTYPE,A,AAAA
from dnslib.server import DNSServer,DNSHandler,BaseResolver,DNSLogger,TCPServer

DEFAULT_IPV6_PREFIX = "fd3a:c9bc:6bcb::/48"
FAKE_IPV6_SUBNET = 0x29FF
FAKE_IPV6_PREFIX_LENGTH = 96
ALTERNATIVE_FAKE_IPV6_NETWORK = IPv6Network("2001:2::/48")


def fake_ipv6_network(prefix, alternative=False):
    if alternative:
        return ALTERNATIVE_FAKE_IPV6_NETWORK
    network = ip_network(prefix,strict=True)
    if not isinstance(network,IPv6Network) or network.prefixlen != 48:
        raise ValueError("VPN IPv6 prefix must be an IPv6 /48 network")
    if not network.subnet_of(IPv6Network("fc00::/7")):
        raise ValueError("VPN IPv6 prefix must be a private ULA /48 network")
    return IPv6Network((int(network.network_address) | (FAKE_IPV6_SUBNET << 64),FAKE_IPV6_PREFIX_LENGTH))


class FakeIPPool:
    def __init__(self,network):
        self.network = ip_network(network,strict=True)
        self.used = set()
        self.released = set()
        self.next_offset = 1

    def claim(self,address):
        value = ip_address(address)
        offset = int(value) - int(self.network.network_address)
        if value not in self.network or offset <= 0 or offset >= self.network.num_addresses - 1:
            return False
        if value in self.used:
            return False
        self.used.add(value)
        self.released.discard(value)
        return True

    def allocate(self):
        if self.released:
            value = self.released.pop()
            self.used.add(value)
            return str(value)
        maximum = self.network.num_addresses - 1
        while self.next_offset < maximum:
            value = ip_address(int(self.network.network_address) + self.next_offset)
            self.next_offset += 1
            if value not in self.used:
                self.used.add(value)
                return str(value)
        return None

    def release(self,address):
        value = ip_address(address)
        if value in self.used:
            self.used.remove(value)
            self.released.add(value)

class ProxyResolver(BaseResolver):
    def __init__(self,address,port,timeout,ip_range,ip6_range,cleanup_interval,cleanup_expiry,min_ttl,max_ttl):
        self._env = os.environ.copy()
        self.pools = {4: FakeIPPool(IPv4Network(ip_range))}
        if ip6_range:
            self.pools[6] = FakeIPPool(IPv6Network(ip6_range))
        self.ip_map = {}
        # Loading existing mappings
        current_time = time.time()
        for family in self.pools:
            result = subprocess.run([self.iptables(family),"-w","-t","nat","-S",self.chain(family)],stdin=subprocess.DEVNULL,stdout=subprocess.PIPE,stderr=subprocess.DEVNULL,text=True,check=True,env=self._env)
            for line in result.stdout.splitlines():
                parts = line.split()
                if len(parts) < 8:
                    continue
                fake_ip = parts[3].split("/")[0]
                real_ip = parts[7]
                if not self.mapping_ip(real_ip,fake_ip,current_time):
                    print("Restarting: Invalid loaded fake IPs mappings")
                    try:
                        self.flush_mappings()
                    finally:
                        os._exit(1)
        print(f"Loaded: {len(self.ip_map)} fake IPs")
        self.address = address
        self.port = port
        self.timeout = timeout
        self.cleanup_interval = cleanup_interval
        self.cleanup_expiry = cleanup_expiry
        self.min_ttl = min_ttl
        self.max_ttl = max_ttl
        self.lock = threading.Lock()
        # Start thread for cleanup fake IPs
        threading.Thread(target=self.cleanup_fake_ips_worker,daemon=True).start()

    @staticmethod
    def iptables(family):
        return "/usr/sbin/ip6tables" if family == 6 else "/usr/sbin/iptables"

    @staticmethod
    def iptables_restore(family):
        return "/usr/sbin/ip6tables-restore" if family == 6 else "/usr/sbin/iptables-restore"

    @staticmethod
    def chain(family):
        return "ANTIZAPRET6-MAPPING" if family == 6 else "ANTIZAPRET-MAPPING"

    def flush_mappings(self):
        for family in self.pools:
            subprocess.run([self.iptables(family),"-w","-t","nat","-F",self.chain(family)],stdin=subprocess.DEVNULL,stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL,check=True,env=self._env)

    def get_fake_ip(self,real_ip,current_time):
        family = ip_address(real_ip).version
        pool = self.pools.get(family)
        if pool is None:
            return None
        with self.lock:
            entry = self.ip_map.get(real_ip)
            if entry:
                entry["last_access"] = current_time
                return entry["fake_ip"]
            fake_ip = pool.allocate()
            if not fake_ip:
                print("Error: No fake IP left")
                return None
            self.ip_map[real_ip] = {"fake_ip": fake_ip,"last_access": current_time}
        try:
            subprocess.run([self.iptables(family),"-w","-t","nat","-A",self.chain(family),"-d",fake_ip,"-j","DNAT","--to-destination",real_ip],stdin=subprocess.DEVNULL,stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL,check=True,env=self._env)
        except Exception as e:
            print(f"Error: {e} (real_ip={real_ip} fake_ip={fake_ip})")
            with self.lock:
                del self.ip_map[real_ip]
                pool.release(fake_ip)
            return None
        #print(f"Mapping: {fake_ip} to {real_ip}")
        return fake_ip

    def mapping_ip(self,real_ip,fake_ip,current_time):
        try:
            real_address = ip_address(real_ip)
            fake_address = ip_address(fake_ip)
        except ValueError:
            return False
        if real_address.version != fake_address.version:
            return False
        pool = self.pools.get(real_address.version)
        if pool is None:
            return False
        if self.ip_map.get(real_ip):
            print(f"Error: Real IP {real_ip} is already mapped")
            return False
        if not pool.claim(fake_ip):
            print(f"Error: Fake IP {fake_ip} not in fake IP pool")
            return False
        self.ip_map[real_ip] = {"fake_ip": str(fake_address),"last_access": current_time}
        #print(f"Mapping: {fake_ip} to {real_ip}")
        return True

    def cleanup_fake_ips_worker(self):
        while True:
            time.sleep(self.cleanup_interval)
            try:
                self.cleanup_fake_ips()
            except Exception as e:
                print(f"Error: {e}")
                print(f"Restarting: Cleanup fake IPs failed")
                try:
                    self.flush_mappings()
                finally:
                    os._exit(1)

    def cleanup_fake_ips(self):
        with self.lock:
            current_time = time.time()
            cleanup_ips = []
            rules = {family: ["*nat"] for family in self.pools}
            for real_ip,entry in self.ip_map.items():
                if current_time - entry["last_access"] > self.cleanup_expiry:
                    cleanup_ips.append((real_ip,entry["fake_ip"]))
            for real_ip,fake_ip in cleanup_ips:
                family = ip_address(real_ip).version
                self.pools[family].release(fake_ip)
                del self.ip_map[real_ip]
                rules[family].append(f"-D {self.chain(family)} -d {fake_ip} -j DNAT --to-destination {real_ip}")
                #print(f"Unmapping: {fake_ip} to {real_ip}")
        if cleanup_ips:
            for family,family_rules in rules.items():
                if len(family_rules) == 1:
                    continue
                family_rules.append("COMMIT")
                subprocess.run([self.iptables_restore(family),"-w","-n"],input="\n".join(family_rules).encode(),stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL,check=True,env=self._env)
            print(f"Cleaned: {len(cleanup_ips)} expired fake IPs")

    def resolve(self,request,handler):
        try:
            if handler.protocol == "udp":
                data = request.send(self.address,self.port,timeout=self.timeout)
            else:
                data = request.send(self.address,self.port,tcp=True,timeout=self.timeout)
            reply = DNSRecord.parse(data)
            if reply.header.rcode == RCODE.NOERROR and request.q.qtype in (QTYPE.A,QTYPE.AAAA) and (request.q.qtype != QTYPE.AAAA or 6 in self.pools):
                new_rr = []
                current_time = time.time()
                qname = request.q.qname
                is_smtp = qname.label and b'smtp' in qname.label[0]
                for record in reply.rr:
                    if record.rtype != request.q.qtype:
                        new_rr.append(record)
                        continue
                    if record.ttl < self.min_ttl:
                        record.ttl = self.min_ttl
                    elif record.ttl > self.max_ttl:
                        record.ttl = self.max_ttl
                    if is_smtp:
                        new_rr.append(copy.copy(record))
                    real_ip = str(record.rdata)
                    fake_ip = self.get_fake_ip(real_ip,current_time)
                    if not fake_ip:
                        reply = request.reply()
                        reply.header.rcode = RCODE.SERVFAIL
                        return reply
                    record.rdata = AAAA(fake_ip) if request.q.qtype == QTYPE.AAAA else A(fake_ip)
                    new_rr.append(record)
                reply.rr = new_rr
        except Exception as e:
            print(f"Error: {e} (qname={request.q.qname} qtype={QTYPE[request.q.qtype]} protocol={handler.protocol})")
            reply = request.reply()
            reply.header.rcode = RCODE.SERVFAIL
        return reply

if __name__ == "__main__":
    p = argparse.ArgumentParser(description="DNS Proxy")
    p.add_argument("--port",type=int,default=53,
                    metavar="<port>",
                    help="Local proxy port (default:53)")
    p.add_argument("--address",default="127.3.3.3",
                    metavar="<address>",
                    help="Local proxy listen address (default:127.3.3.3)")
    p.add_argument("--upstream",default="127.2.2.2:53",
                    metavar="<dns server:port>",
                    help="Upstream DNS server:port (default:127.2.2.2:53)")
    p.add_argument("--timeout",type=float,default=5,
                    metavar="<timeout>",
                    help="Upstream timeout (default: 5s)")
    p.add_argument("--log",default="truncated,error",
                    help="Log hooks to enable (default: +truncated,+error,-request,-reply,-recv,-send,-data)")
    p.add_argument("--log-prefix",action="store_true",default=False,
                    help="Log prefix (timestamp/handler/resolver) (default: False)")
    p.add_argument("--ip-range",default="198.18.0.0/15",
                    metavar="<ip/mask>",
                    help="Fake IP range (default:198.18.0.0/15)")
    p.add_argument("--ip6-range",default=str(fake_ipv6_network(
                        os.environ.get("VPN_IPV6_PREFIX") or DEFAULT_IPV6_PREFIX,
                        os.environ.get("ALTERNATIVE_FAKE_IPV6", "y") == "y",
                    )),
                    metavar="<ipv6/mask>",
                    help="Fake IPv6 range selected by setup")
    p.add_argument("--disable-ipv6",action="store_true",default=os.environ.get("DISABLE_IPV6","n") == "y",
                    help="Disable AAAA rewriting and IPv6 mappings")
    p.add_argument("--cleanup-interval",type=int,default=3600,
                    metavar="<seconds>",
                    help="Seconds between fake IP cleanup runs (default: 3600)")
    p.add_argument("--cleanup-expiry",type=int,default=7200,
                    metavar="<seconds>",
                    help="Seconds of inactivity before fake IP is removed (default: max-ttl * 2)")
    p.add_argument("--min-ttl",type=int,default=0,
                    metavar="<seconds>",
                    help="Minimum TTL in seconds (default: 0)")
    p.add_argument("--max-ttl",type=int,default=3600,
                    metavar="<seconds>",
                    help="Maximum TTL in seconds (default: 3600)")
    args = p.parse_args()
    if args.min_ttl < 0 or args.max_ttl < 1 or args.min_ttl > args.max_ttl:
        p.error("TTL limits must satisfy 0 <= min-ttl <= max-ttl")
    args.dns,_,args.dns_port = args.upstream.partition(":")
    args.dns_port = int(args.dns_port or 53)
    TCPServer.request_queue_size = 128
    print("Starting Proxy Resolver...")
    resolver = ProxyResolver(args.dns,args.dns_port,args.timeout,args.ip_range,None if args.disable_ipv6 else args.ip6_range,args.cleanup_interval,args.cleanup_expiry,args.min_ttl,args.max_ttl)
    logger = DNSLogger(args.log,prefix=args.log_prefix)
    udp_server = DNSServer(resolver,
                           port=args.port,
                           address=args.address,
                           logger=logger,
                           handler=DNSHandler)
    udp_server.start_thread()
    tcp_server = DNSServer(resolver,
                           port=args.port,
                           address=args.address,
                           tcp=True,
                           logger=logger,
                           handler=DNSHandler)
    tcp_server.start_thread()
    print("Started Proxy Resolver: %s:%d -> %s:%d" % (args.address or "*",args.port,args.dns,args.dns_port))
    while udp_server.isAlive():
        time.sleep(1)
