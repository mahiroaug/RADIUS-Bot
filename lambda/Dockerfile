FROM public.ecr.aws/lambda/python:3.11

# Install system deps: certbot + route53 plugin + curl + zip
RUN microdnf install -y epel-release || true \
 && microdnf install -y certbot python3-certbot-dns-route53 curl tar gzip \
 && microdnf clean all || true

COPY handler.py requirements.txt entrypoint.sh ./
RUN pip3 install -r requirements.txt --target "/opt/python"

RUN chmod +x entrypoint.sh

CMD ["entrypoint.sh"]


