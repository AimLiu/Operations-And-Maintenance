# create-topics.sh
TOPIC=device-report-events
PARTITIONS=3
REPLICATION=1
# kafka-topics.sh --create --topic $TOPIC --partitions $PARTITIONS ...