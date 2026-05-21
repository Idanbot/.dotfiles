# ec2-info — Pretty-print all EC2 instances in a table
ec2-info() {
  aws ec2 describe-instances \
    --query 'Reservations[].Instances[].{
      ID:InstanceId,
      Name: Tags[?Key==`Name`]|[0].Value,
      State: State.Name,
      Type: InstanceType,
      PrivateIP: PrivateIpAddress,
      PublicIP: PublicIpAddress,
      AZ: Placement.AvailabilityZone,
      LaunchTime: LaunchTime
      }' \
    --output table
}
