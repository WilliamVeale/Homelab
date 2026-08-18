# Kubernetes homelab via Flux GitOps

This will document the creation of my Kubernetes homelab. I am focusing on creating this using GitOps principles via Flux. 

So far I have implemented:
- `linkding` - bookmark manager
- `mealie` - recipe manager
- `kube-prometheus-stack` for cluster monitoring
- CF Tunnels for external access
- Plex Media Server
- `vikunja` - task manager (private: Cloudflare Tunnel only, no Ingress, self-registration disabled, NetworkPolicy limits pod ingress to `cloudflared`)

### Future Goals
- NAS for photography storage and editing. As well as iSCSI/NFS support for the K8s cluster.
- Separate Control Plane node from Worker Node hardware
- Browsertrix Helm deployment
- Cluster backups 
- and more!
