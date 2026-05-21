# ssm-connect — Connect to an EC2 instance via SSM by Name tag
ssm-connect() {
  local NAME=$1
  if [[ -z "$NAME" ]]; then
    echo "Usage: ssm-connect <instance-name-tag>"
    return 1
  fi
  local ID
  ID=$(aws ec2 describe-instances \
    --filters "Name=tag:Name,Values=$NAME" "Name=instance-state-name,Values=running" \
    --query "Reservations[0].Instances[0].InstanceId" --output text)
  if [[ "$ID" == "None" ]] || [[ -z "$ID" ]]; then
    echo "No running instance found with Name=$NAME"
    return 1
  fi
  echo "Connecting to $NAME ($ID)..."
  aws ssm start-session --target "$ID"
}
