# Pinned to a dated release tag for reproducible builds. NOTE: upstream
# searxng/searxng only keeps rolling date-stamped tags (e.g. 2026.6.22-<sha>)
# and prunes older ones, so an old pin can disappear from Docker Hub and break
# the build. Bump this to a current tag (see `docker buildx imagetools inspect
# searxng/searxng:<tag>`), or pin to an immutable digest for maximum stability:
#   FROM searxng/searxng@sha256:<digest>
FROM searxng/searxng:2026.6.22-952896d29

COPY settings.yml /etc/searxng/settings.yml
