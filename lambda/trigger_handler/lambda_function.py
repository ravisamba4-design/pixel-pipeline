import json
import boto3
import uuid
import os
from datetime import datetime, timezone
from urllib.parse import unquote_plus

dynamodb = boto3.resource('dynamodb')
sqs = boto3.client('sqs')

TABLE_NAME = 'pixel-pipeline-jobs'
QUEUE_URL = os.environ.get('QUEUE_URL')

table = dynamodb.Table(TABLE_NAME)


def lambda_handler(event, context):
    # S3 event notifications can contain multiple records in one event
    for record in event.get('Records', []):
        bucket_name = record['s3']['bucket']['name']
        object_key = unquote_plus(record['s3']['object']['key'])

        job_id = str(uuid.uuid4())
        now = datetime.now(timezone.utc).isoformat()

        # 1. Write a "queued" record to DynamoDB
        table.put_item(Item={
            'job_id': job_id,
            'status': 'queued',
            'source_bucket': bucket_name,
            'source_key': object_key,
            'created_at': now,
            'updated_at': now
        })

        # 2. Push a message to SQS for the processor Lambda to pick up
        sqs.send_message(
            QueueUrl=QUEUE_URL,
            MessageBody=json.dumps({
                'job_id': job_id,
                'bucket': bucket_name,
                'key': object_key
            })
        )

    return {
        'statusCode': 200,
        'body': json.dumps({'message': 'Processed S3 event, jobs queued'})
    }
