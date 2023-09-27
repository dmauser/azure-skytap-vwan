# This is an script to create emulated on-premises and skytap using GCP.
# Both get interconnected via Megaport to Azure ExpressRoutes.
# Create environments:
envname1=onprem-dal
vpcrange1="10.154.0.0/24"
envname2=skytap-chi
vpcrange2="10.10.0.0/24"

# Parameters:
project=angular-expanse-327722 #Set your project Name. Get your PROJECT_ID use command: gcloud projects list 
region=us-central1 #Set your region. Get Regions/Zones Use command: gcloud compute zones list
zone=us-central1-b # Set availability zone: a, b or c.
mypip=$(curl -4 ifconfig.io -s) #Gets your Home Public IP or replace with that information. It will add it to the Firewall Rule.

# echo array for each environment
env=( $envname1 $envname2 )
vpc=( $vpcrange1 $vpcrange2 )

for i in "${!env[@]}"; do 
    echo "Creating ${env[$i]} with VPC range ${vpc[$i]}"
    #Create VPC + Subnet
    gcloud config set project $project
    gcloud compute networks create ${env[$i]}-vpc --subnet-mode=custom --mtu=1460 --bgp-routing-mode=regional
    gcloud compute networks subnets create ${env[$i]}-subnet --range=${vpc[$i]} --network=${env[$i]}-vpc --region=$region
    #Create Firewall Rule
    gcloud compute firewall-rules create ${env[$i]}-allow-traffic-from-azure --network ${env[$i]}-vpc --allow tcp,udp,icmp --source-ranges 192.168.0.0/16,10.0.0.0/8,172.16.0.0/16,35.235.240.0/20,$mypip/32
    #Create Unbutu VM:
    gcloud compute instances create ${env[$i]}-vm1 --zone=$zone --machine-type=f1-micro --network-interface=subnet=${env[$i]}-subnet,network-tier=PREMIUM --image-family=ubuntu-2204-lts --image-project=ubuntu-os-cloud --boot-disk-size=10GB --boot-disk-type=pd-balanced --boot-disk-device-name=${env[$i]}-vm1 
    #Cloud Router: #***********Validate************
    gcloud compute routers create ${env[$i]}-router --region=$region --network=${env[$i]}-vpc --asn=16550
    #DirectConnect via MegaPort:
    gcloud compute interconnects attachments partner create ${env[$i]}-vlan --region $region --edge-availability-domain availability-domain-1 --router ${env[$i]}-router --admin-enabled
done

# loop script to describe each interconnect environment
for i in "${!env[@]}"; do 
    echo "Describing ${env[$i]} with VPC range ${vpc[$i]}"
    gcloud compute interconnects attachments describe ${env[$i]}-vlan --region $region --format='value(name, pairingKey)'
done

# Provision Interconnects with the Provider

# Adjust Route propagation On-premises
#Route propagation
bgpsession=$(gcloud compute routers describe $envname1-router --region=$region --format='value(bgpPeers.name)')
gcloud compute routers update-bgp-peer $envname1-router \
 --peer-name $bgpsession \
 --advertisement-mode custom \
 --set-advertisement-ranges 10.0.0.0/9,10.128.0.0/9,172.16.0.0/13,172.24.0.0/13,192.168.0.0/17,192.168.128.0/17 \
 --region=$region

# Adjust Route propagation for Skytap
#Route propagation
bgpsession=$(gcloud compute routers describe $envname2-router --region=$region --format='value(bgpPeers.name)')
gcloud compute routers update-bgp-peer $envname2-router \
 --peer-name $bgpsession \
 --advertisement-mode custom \
 --set-advertisement-ranges 10.10.0.0/25,10.10.0.128/25 \
 --region=$region

# Access VMs
gcloud compute ssh $envname1-vm1 --zone=$zone
gcloud compute ssh $envname2-vm1 --zone=$zone

# DANGER **** Cleanup ****
# echo array for each environment
env=( $envname1 $envname2 )
vpc=( $vpcrange1 $vpcrange2 )

for i in "${!env[@]}"; do 
    echo "Deleting ${env[$i]} with VPC range ${vpc[$i]}"
    gcloud compute interconnects attachments delete ${env[$i]}-vlan --region $region --quiet 
    gcloud compute routers delete ${env[$i]}-router --region=$region --quiet
    gcloud compute instances delete ${env[$i]}-vm1 --zone=$zone --quiet
    gcloud compute firewall-rules delete ${env[$i]}-allow-traffic-from-azure --quiet
    gcloud compute networks subnets delete ${env[$i]}-subnet --region=$region --quiet
    gcloud compute networks delete ${env[$i]}-vpc --quiet
done


