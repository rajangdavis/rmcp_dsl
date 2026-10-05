# typed: true
# Addresses: resolve a host name and decide whether an address is public. Both use only the standard library
# (std::net), so the crate list is empty. This is the half of a request guard that cannot be written in the
# DSL: DNS resolution and IP classification. A host that does not resolve gives nil; an address that does not
# parse is not public. Examples use IP literals so they need no network.
module Net
  extend T::Sig
  extend RmcpDsl::BindingDsl

  # The addresses a host name resolves to, as text; nil when it does not resolve.
  rust "std::net::ToSocketAddrs::to_socket_addrs(&(host, 0u16)).ok().map(|it| it.map(|a| a.ip().to_string()).collect::<Vec<String>>())"
  no_reference "needs the resolver of the machine the server runs on"
  sig { params(host: String).returns(T.nilable(T::Array[String])) }
  def self.addresses(host) = raise(NotImplementedError, "no Ruby stand-in")
  example :addresses, "127.0.0.1", expect: ["127.0.0.1"]
  example :addresses, "::1", expect: ["::1"]

  # True only for a globally routable address: not loopback, private, link-local (169.254.x.x, which holds
  # cloud metadata services), carrier-grade NAT, multicast, documentation, unique-local or unspecified.
  # An IPv4-mapped IPv6 address is judged as the IPv4 address it wraps. Text that is not an IP is false.
  rust "ip.parse::<std::net::IpAddr>().map(|a| { let a = match a { std::net::IpAddr::V6(v6) => v6.to_ipv4_mapped().map(std::net::IpAddr::V4).unwrap_or(a), _ => a }; match a { std::net::IpAddr::V4(v4) => { let o = v4.octets(); !(v4.is_loopback() || v4.is_private() || v4.is_link_local() || v4.is_unspecified() || v4.is_broadcast() || v4.is_documentation() || v4.is_multicast() || o[0] == 0 || (o[0] == 100 && (o[1] & 0xC0) == 64) || o[0] >= 240) } std::net::IpAddr::V6(v6) => { let s = v6.segments(); !(v6.is_loopback() || v6.is_unspecified() || v6.is_multicast() || (s[0] & 0xfe00) == 0xfc00 || (s[0] & 0xffc0) == 0xfe80) } } }).unwrap_or(false)"
  no_reference "the classification follows the standard library's; Ruby's IPAddr has no equivalent list"
  sig { params(ip: String).returns(T::Boolean) }
  def self.public_address?(ip) = raise(NotImplementedError, "no Ruby stand-in")
  example :public_address?, "8.8.8.8", expect: true
  example :public_address?, "1.1.1.1", expect: true
  example :public_address?, "2606:4700:4700::1111", expect: true
  example :public_address?, "127.0.0.1", expect: false
  example :public_address?, "10.0.0.1", expect: false
  example :public_address?, "192.168.1.1", expect: false
  example :public_address?, "172.16.0.1", expect: false
  example :public_address?, "169.254.169.254", expect: false
  example :public_address?, "100.64.0.1", expect: false
  example :public_address?, "0.0.0.0", expect: false
  example :public_address?, "255.255.255.255", expect: false
  example :public_address?, "224.0.0.1", expect: false
  example :public_address?, "::1", expect: false
  example :public_address?, "fc00::1", expect: false
  example :public_address?, "fe80::1", expect: false
  example :public_address?, "::ffff:127.0.0.1", expect: false
  example :public_address?, "not an ip", expect: false
  example :public_address?, "", expect: false
end
