import json
import boto3
import os
from io import BytesIO
from datetime import datetime, timezone
from PIL import Image

s3 = boto3.client('s3')
dynamodb = boto3.resource('dynamodb')

TABLE_NAME = 'pixel-pipeline-jobs'
PROCESSED_BUCKET = os.environ.get('PROCESSED_BUCKET')
THUMBNAIL_SIZE = (300, 300)

table = dynamodb.Table(TABLE_NAME)


def lambda_handler(event, context):
    # SQS can deliver multiple messages in one batch
    for record in event.get('Records', []):
        body = json.loads(record['body'])
        job_id = body['job_id']
        source_bucket = body['bucket']
        source_key = body['key']

        try:
            update_status(job_id, 'processing')

            # 1. Download the original image into memory
            response = s3.get_object(Bucket=source_bucket, Key=source_key)
            image_data = response['Body'].read()

            # 2. Resize it using Pillow
            image = Image.open(BytesIO(image_data))
            image.thumbnail(THUMBNAIL_SIZE)

            # 3. Save the resized image to an in-memory buffer
            output_buffer = BytesIO()
            image_format = image.format or 'JPEG'
            image.save(output_buffer, format=image_format)
            output_buffer.seek(0)

            # 4. Upload the processed image to the second bucket
            processed_key = f"processed-{source_key}"
            s3.put_object(
                Bucket=PROCESSED_BUCKET,
                Key=processed_key,
                Body=output_buffer,
                ContentType=f"image/{image_format.lower()}"
            )

            update_status(job_id, 'complete', processed_key=processed_key)

        except Exception as e:
            update_status(job_id, 'failed', error=str(e))

    return {'statusCode': 200, 'body': json.dumps({'message': 'Batch processed'})}


def update_status(job_id, status, processed_key=None, error=None):
    update_expr = "SET #s = :s, updated_at = :u"
    expr_values = {
        ':s': status,
        ':u': datetime.now(timezone.utc).isoformat()
    }
    expr_names = {'#s': 'status'}

    if processed_key:
        update_expr += ", processed_key = :p"
        expr_values[':p'] = processed_key

    if error:
        update_expr += ", error_message = :e"
        expr_values[':e'] = error

    table.update_item(
        Key={'job_id': job_id},
        UpdateExpression=update_expr,
        ExpressionAttributeValues=expr_values,
        ExpressionAttributeNames=expr_names
    )
