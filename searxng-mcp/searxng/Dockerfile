# Pinned to a dated stable release tag instead of :latest for reproducible builds.
# In real production, pin to an immutable digest, e.g.
#   FROM searxng/searxng@sha256:<digest>
# (resolve via: docker buildx imagetools inspect searxng/searxng:2025.6.1)
FROM searxng/searxng:2025.6.1

COPY settings.yml /etc/searxng/settings.yml
