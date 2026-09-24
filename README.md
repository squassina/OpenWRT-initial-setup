# OpenWrt Script Execution via SSH

## Preparation

1. **Send the script to the OpenWrt router**

   Run **on your computer**:

   ```bash
   scp setup-router-home-iot-xbox-dns-redirect-tests.sh root@192.168.1.1:/root/
   ```

   If the file is in your `Downloads` folder:

   ```bash
   scp ~/Downloads/setup-router-home-iot-xbox-dns-redirect-tests.sh root@192.168.1.1:/root/
   ```

---

1. **Connect to the router**

   ```bash
   ssh root@192.168.1.1
   ```

---

1. **Confirm that the file was uploaded**

   ```sh
   ls -lh /root/setup-router-home-iot-xbox-dns-redirect-tests.sh
   ```

---

1. **Validate syntax before execution**

   ```sh
   sh -n /root/setup-router-home-iot-xbox-dns-redirect-tests.sh
   ```

   Expected output: none. If an error is returned, **do not execute the script**.

---

1. **Execute the script**

   ```sh
   HOME_WIFI_KEY='YOUR_HOME_PASSWORD' \
   IOT_WIFI_KEY='YOUR_IOT_PASSWORD' \
   HOME_SSID_2G='HOME-2G' \
   HOME_SSID_5G='HOME-5G' \
   IOT_SSID='HOME-IOT' \
   sh /root/setup-router-home-iot-xbox.sh
   ```

   The script will back up configuration files before applying any changes. Backups are stored in:

   ```text
   /root/backup/
   ```

---

1. **Connection Warning**

   Perform this procedure while connected via an Ethernet cable to one of the following ports:

   * LAN1
   * LAN2
   * LAN3

   **Do not use LAN4/Xbox to manage the router.** LAN4 is dedicated to the Xbox network.

---

## DNS Redirect Validation

After running the script, first confirm that the `dstnat` rule was created.

1. **Verify DNAT rules**

   ```sh
   nft list chain inet fw4 dstnat
   ```

   Also check:

   ```sh
   fw4 print | grep -E -A5 -B5 'Redirect-(IoT|Xbox)-DNS'
   ```

   A DNS redirection rule targeting the local Pi-hole instance must exist.

---

1. **Verify IoT VLAN firewall**

   ```sh
   nft list chain inet fw4 forward_iot
   ```

   Look for rules related to:

   ```text
   dport 53      # DNS
   dport 853     # DNS-over-TLS
   ```

---

1. **Verify Xbox VLAN firewall**

   ```sh
   nft list chain inet fw4 forward_xbox
   ```

   Look for rules related to:

   ```text
   dport 53      # DNS
   dport 853     # DNS-over-TLS
   ```

---

1. **Test static DNS configuration — IoT**

   This test must be executed **from a device connected to the IoT network**, not directly from the router.

   Configure the device to manually use a static DNS server, such as:

   ```text
   8.8.8.8
   ```

   Then execute:

   ```sh
   nslookup openwrt.org 8.8.8.8
   ```

   Repeat with:

   ```sh
   nslookup openwrt.org 1.1.1.1
   ```

   And:

   ```sh
   nslookup openwrt.org 9.9.9.9
   ```

   ### Expected Result

   All three queries should complete successfully. The device must not return an error simply because it uses an external/static DNS server.

   ```mermaid
   graph TD
       IoT[IoT Device] -->|DNS Request: 8.8.8.8:53| OpenWrt[OpenWrt Router]
       OpenWrt -->|DNAT Interception| PiHole[Local Pi-hole: 192.168.1.3:53]
   ```

---

1. **Test static DNS configuration — Xbox**

   From a device on the Xbox VLAN, execute:

   ```sh
   nslookup xbox.com 8.8.8.8
   ```

   Then:

   ```sh
   nslookup xbox.com 1.1.1.1
   ```

   And:

   ```sh
   nslookup xbox.com 9.9.9.9
   ```

   Also validate directly against the local Pi-hole instances:

   ```sh
   nslookup xbox.com 192.168.1.3
   ```

   ```sh
   nslookup xbox.com 192.168.1.4
   ```

   ### Expected Result

   All DNS tests must resolve correctly. Specifically, manual DNS servers such as `8.8.8.8`, `1.1.1.1`, and `9.9.9.9` should continue to function seamlessly via interception.

---

1. **Confirm redirection using tcpdump**

   While executing queries on the IoT network, capture traffic on the router:

   ```sh
   tcpdump -ni br-iot 'udp port 53 or tcp port 53'
   ```

   For the Xbox VLAN:

   ```sh
   tcpdump -ni br-lan.21 'udp port 53 or tcp port 53'
   ```

   Re-run a DNS query on the client device while monitoring traffic.

---

1. **Verify nftables counters**

   After executing test queries, review counter increments:

   ```sh
   nft list chain inet fw4 dstnat
   ```

   ```sh
   nft list chain inet fw4 forward_iot
   ```

   ```sh
   nft list chain inet fw4 forward_xbox
   ```

   The counters for the DNS rules should increase as queries are made.

---

1. **Test DNS resolution directly on Pi-hole instances**

   From the router command line:

   ```sh
   nslookup openwrt.org 192.168.1.3
   ```

   ```sh
   nslookup openwrt.org 192.168.1.4
   ```

   Both servers must reply.

---

1. **Target Architecture**

   The resulting network flow operates as follows:

   ```mermaid
   graph TD
       Internet[Internet] --- OpenWrt["OpenWrt Firewall (fw4)"]
       
       subgraph Subnets ["Internal Networks"]
           IoT["VLAN IoT<br/>192.168.50.0/24"]
           Xbox["VLAN Xbox<br/>192.168.51.0/24"]
       end

       OpenWrt --- Subnets

       IoT -->|"Static DNS (e.g., 8.8.8.8)"| DNAT["DNAT Port 53"]
       Xbox -->|"Static DNS (e.g., 1.1.1.1)"| DNAT

       DNAT --> PiHole["Local Pi-hole Servers<br/>192.168.1.3<br/>192.168.1.4"]
   ```

   > **Key Takeaway:** A manually configured static DNS on a client device must not result in blocked queries or errors. OpenWrt intercepts IPv4 queries on port 53 and forwards them to the local Pi-hole DNS instances.

---

 1. **DNS-over-TLS (DoT) Handling**

    DNS-over-TLS utilizes the following ports:

    ```text
    853/TCP
    853/UDP
    ```

    These encrypted connections are intentionally blocked or rejected. Verify with:

    ```sh
    nft list chain inet fw4 forward_iot
    ```

    And:

    ```sh
    nft list chain inet fw4 forward_xbox
    ```

    Look for rules matching `dport 853`.

---

 1. **DNS-over-HTTPS (DoH) Handling**

    The current script **does not block DoH over HTTPS/443**.

    The static DNS test scenario covers:
    * Traditional DNS over UDP/53
    * Traditional DNS over TCP/53
    * DNAT redirection to Pi-hole
    * Manually configured external DNS servers

    It does not intercept or block DoH over HTTPS/443.

---

 1. **Information to Collect for Troubleshooting**

    If issues arise, collect and provide the output of these commands:

    ```sh
    nft list chain inet fw4 dstnat
    ```

    ```sh
    nft list chain inet fw4 forward_iot
    ```

    ```sh
    nft list chain inet fw4 forward_xbox
    ```

    ```sh
    fw4 print | grep -E -A10 -B10 'Redirect-(IoT|Xbox)-DNS'
    ```

    And capture packets during a static DNS request:

    ```sh
    tcpdump -ni br-iot 'udp port 53 or tcp port 53'
    ```

    or:

    ```sh
    tcpdump -ni br-lan.21 'udp port 53 or tcp port 53'
    ```

    This helps verify whether outbound requests (`client -> external DNS:53`) are being correctly transformed into `client -> local Pi-hole:53` without triggering a `REJECT` or `DROP`.
