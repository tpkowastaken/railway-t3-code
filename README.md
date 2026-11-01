# Deploy and Host T3 Code on Railway

[![Deploy on Railway](https://railway.com/button.svg)](https://railway.com/new/template/t3-code?referralCode=UEjeDc&utm_medium=integration&utm_source=button&utm_campaign=t3-code)

T3 Code is the open-source "agent harness control surface": a server that runs coding agents (Claude Code, Codex, OpenCode and more) on a machine, and web, desktop and mobile apps that drive them from anywhere. This template makes that machine a Railway service: a cloud agent box with Claude Code, Codex and OpenCode preinstalled, so your agents keep working with the laptop closed and you check in from your phone.

https://github.com/tpkowastaken/railway-t3-code

## About Hosting - Setup

1. Add this template
2. Once the application is deployed, copy **T3_SETUP_PASSWORD** from the service's Variables tab
3. Open the public link from railway (click the instance, then Settings, and it's under Networking). Until a browser is paired, the link opens the **/railway-pair** page, which also explains where to find the password
4. Enter that password, then click **Pair this browser**. For your phone, scan the QR code in the T3 Code app (Settings → Environments → Add). Reload the page for a new link for each device

## Agent configs

Because of it running in a container the agents are instructed to install tools in a way that persists. The instructions are at [default global agent.md](default%20global%20agent.md) - placed at the top of the global instructions for Claude Code, Codex, OpenCode, Antigravity/Gemini, Pi and fx. Your own text in those files, outside the marked block, is kept.

## Remote Docker

Railway can't run a Docker daemon, but the image has the **docker** CLI (with **compose** and **buildx**) and can use a daemon on another machine over SSH. Agents then use **docker** and **docker compose** as usual. This is required for local supabase for instance

1. Get a Linux VM with Docker installed (a small VPS is enough; 4 GB+ RAM for heavier stacks like Supabase). Use a dedicated machine: access to Docker is root on that host.
2. On the VM, create a user in the **docker** group and authorize a new key for it:
   ```
   ssh-keygen -t ed25519 -N "" -f t3-docker   # run anywhere; gives t3-docker and t3-docker.pub
   sudo useradd -m -G docker agent
   sudo install -d -m 700 -o agent -g agent /home/agent/.ssh
   sudo tee /home/agent/.ssh/authorized_keys < t3-docker.pub
   ```
3. Keep containers' ports off the internet. Every published port is forwarded to **127.0.0.1** in the T3 container automatically, so nothing needs to be public:
   - Make Docker publish on the VM's loopback by default: put **{ "ip": "127.0.0.1" }** in **/etc/docker/daemon.json** and run **sudo systemctl restart docker**. A plain **ufw** firewall is not enough on its own, because Docker's published ports bypass it.
   - Also allow only SSH (22) in your provider's firewall (e.g. Hetzner Cloud Firewall), if it has one.
4. For **docker-forward reverse** (containers reaching a dev server in the T3 container):
   - Add **GatewayPorts clientspecified** to the VM's **/etc/ssh/sshd_config** and restart sshd.
   - With **ufw**, also allow Docker's networks to reach the host: **sudo ufw allow from 172.16.0.0/12**.
5. Set these in the service's **Variables** tab and redeploy:

| Variable | Required | Value |
| --- | --- | --- |
| **DOCKER_HOST** | yes | **ssh://agent@VM_IP** (add **:PORT** if SSH isn't on 22) |
| **DOCKER_SSH_KEY** | yes | Contents of the private key file **t3-docker** (multi-line is fine, or base64 of it) |
| **DOCKER_SSH_KNOWN_HOSTS** | recommended | Output of **ssh-keyscan VM_IP** (**ssh-keyscan -p PORT VM_IP** for another port). Without it the first host key seen is trusted and remembered |

Check it from the T3 terminal with **docker info**. The port forwards are logged in the deploy logs (prefix **docker-forward:**), and **docker-forward list** shows them. Agents are told what works differently with a remote daemon (bind mounts refer to the VM's disk, reverse tunnels for containers that call back, ...) in [default global agent.md](default%20global%20agent.md).

## Common Use Cases

- Going to work and then closing your laptop
- Using your phone to code
- It has browser preinstalled so that the agent can access and check itself even when you close the lid of your laptop

## Dependencies for T3 Code Hosting

- You will need to have an ai subscription that works with one of the providers supported with T3 code. Chatgpt or claude for example. OpenCode's free models work without one.

## Why Deploy T3 Code on Railway?

Railway is a singular platform to deploy your infrastructure stack. Railway will host your infrastructure so you don't have to deal with configuration, while allowing you to vertically and horizontally scale it.

By deploying T3 Code on Railway, you are one step closer to supporting a complete full-stack application with minimal burden. Host your servers, databases, AI agents, and more on Railway.

It's a one click setup for an ai agent where you own the data.

## Disclaimer

This is not affiliated with Theo. You are welcomed to fork, expand and contribute.
Railway doesn't support docker in docker setups.
