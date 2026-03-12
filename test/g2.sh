# Create a GPU spot instance in Google Cloud Platform g2-standard-8 to test region evailability and performance.

gcloud compute instances create test-gpu-spot \
    --zone=us-central1-a \
    --machine-type=g2-standard-8 \
    --provisioning-model=SPOT \
    --instance-termination-action=STOP \
    --maintenance-policy=TERMINATE \
    --boot-disk-size=50GB \
    --boot-disk-type=pd-balanced \
    --image-family=debian-12 \
    --image-project=debian-cloud \
    --network=zenek-wvzg6-network \
    --subnet=zenek-wvzg6-master-subnet

# zenek-wvzg6-master-subnet  us-central1  zenek-wvzg6-network  10.0.0.0/17    IPV4_ONLY
