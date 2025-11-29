# Custom WordPress image (Docker dev)

This folder builds a WordPress image with:
- Redis PHP extension preinstalled and enabled.
- Apache docroot rewired to `/usr/src/wordpress` (matches our mounted code).
- A symlinked `wp-config.php` from `wp-config-docker.php` so env vars drive config.

## Build and push (example)
```bash
cd .dockerdev
export WORDPRESS_VERSION=latest          # or pin a version, e.g. 6.6.2-php8.2-apache
export IMAGE_TAG=my-dockerhub-username/wordpress-redis:$WORDPRESS_VERSION

docker build --build-arg WORDPRESS_VERSION=$WORDPRESS_VERSION -t $IMAGE_TAG .
docker push $IMAGE_TAG
```

## Use the image
- In your stack files, set `image: my-dockerhub-username/wordpress-redis:TAG`.
- Or pull directly to test locally:  
  `docker pull my-dockerhub-username/wordpress-redis:TAG`

## Why this Dockerfile?
- Keeps WordPress core aligned with a specific upstream tag.
- Enables Redis object cache out-of-the-box.
- Uses environment-driven `wp-config` for containerized deployments.
- Adjusts Apache docroot to the mounted code path so your bind mounts work seamlessly.
