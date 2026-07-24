import json
import boto3
import os
from datetime import datetime, timezone
from decimal import Decimal

s3 = boto3.client('s3')
dynamodb = boto3.resource('dynamodb')

TABLE_NAME = 'pixel-pipeline-jobs'
UPLOADS_BUCKET = os.environ.get('UPLOADS_BUCKET')
API_SECRET = os.environ.get('API_SECRET')

table = dynamodb.Table(TABLE_NAME)


class DecimalEncoder(json.JSONEncoder):
    def default(self, obj):
        if isinstance(obj, Decimal):
            return int(obj) if obj % 1 == 0 else float(obj)
        return super().default(obj)


def respond(status_code, body):
    return {
        'statusCode': status_code,
        'headers': {
            'Content-Type': 'application/json'
        },
        'body': json.dumps(body, cls=DecimalEncoder)
    }


def lambda_handler(event, context):
    if event.get('requestContext', {}).get('http', {}).get('method') == 'OPTIONS':
        return respond(200, {})

    body = event
    if 'body' in event and isinstance(event['body'], str):
        body = json.loads(event['body'])

    headers = event.get('headers', {}) or {}
    incoming_key = headers.get('x-api-key') or headers.get('X-Api-Key') or body.get('api_key')

    if not API_SECRET or incoming_key != API_SECRET:
        return respond(401, {"error": "Unauthorized"})

    action = body.get('action')

    if action == 'get_upload_url':
        return handle_get_upload_url(body)
    elif action == 'list_jobs':
        return handle_list_jobs()
    else:
        return respond(400, {"error": f"Unsupported action: {action}"})


def handle_get_upload_url(body):
    filename = body.get('filename')
    if not filename:
        return respond(400, {"error": "filename is required"})

    try:
        presigned_url = s3.generate_presigned_url(
            'put_object',
            Params={'Bucket': UPLOADS_BUCKET, 'Key': filename},
            ExpiresIn=300  # URL valid for 5 minutes
        )
        return respond(200, {"upload_url": presigned_url, "filename": filename})
    except Exception as e:
        return respond(500, {"error": str(e)})


def handle_list_jobs():
    try:
        result = table.scan()
        items = result.get('Items', [])
        items.sort(key=lambda x: x.get('created_at', ''), reverse=True)
        return respond(200, {"items": items})
    except Exception as e:
        return respond(500, {"error": str(e)})
