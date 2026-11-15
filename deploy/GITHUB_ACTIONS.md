# Automatic deployment to Hostinger

Pushes to main and manual runs of Deploy to Hostinger deploy the selected commit to tasks.molotilka.site. Runs are serialized. The production environment links to the live site.

GitHub Secrets hold HOSTINGER_HOST, HOSTINGER_KNOWN_HOSTS and HOSTINGER_DEPLOY_KEY. SSH connects as taskdeploy, whose only sudo command is the deployment script. The SSH key is restricted to the installed /usr/local/sbin/task-manager-deploy command. It accepts a commit SHA and downloads source from bots-n-bones/task-manager. The server host key is pinned.

The deployment checks JavaScript syntax and browser compatibility, takes a database and file backup, builds and restarts web and bot, and checks public health. Failed builds or health checks restore the previous application source and images. Backups are stored in /opt/team-task-manager/backups.

Database migrations require a separate reviewed operation. The deployment does not execute migrations or rebuild the Supabase services. Apply schema changes before publishing code that requires them.

The server keeps production secrets in deploy/.env.production. The deployed commit is recorded in /opt/team-task-manager/.deployed-revision. A manual workflow run redeploys the current main commit. To return to an earlier source version, revert the relevant commits on main and push.

Changes to deploy/hostinger-deploy.sh must also be installed at /usr/local/sbin/task-manager-deploy through the administrator SSH connection. Backups and Docker images should be included in regular disk maintenance.
