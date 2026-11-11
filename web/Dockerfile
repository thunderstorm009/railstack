# syntax=docker/dockerfile:1
#
# ReliStack web — NGINX reverse proxy + static landing page.
#
# The official NGINX image already contains NGINX itself, the mime types and a
# set of entrypoint helper scripts, so this image only layers our own
# configuration on top of it.

FROM nginx:1.29-alpine

# Replace the stock config entirely: shipping our own file is easier to reason
# about than patching the image's multi-file layout.
COPY nginx.conf /etc/nginx/nginx.conf
COPY static/ /usr/share/nginx/html/
COPY relistack-entrypoint.sh /usr/local/bin/relistack-entrypoint.sh

RUN chmod +x /usr/local/bin/relistack-entrypoint.sh \
    && rm -f /etc/nginx/conf.d/default.conf

EXPOSE 8080

# Alpine ships BusyBox wget, so no extra package is needed for the probe.
HEALTHCHECK --interval=10s --timeout=3s --start-period=5s --retries=3 \
    CMD wget -qO- http://127.0.0.1:8080/healthz >/dev/null || exit 1

ENTRYPOINT ["/usr/local/bin/relistack-entrypoint.sh"]
CMD ["nginx", "-g", "daemon off;"]
