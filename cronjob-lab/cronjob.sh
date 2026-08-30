oc create cronjob app-health-check --image=curlimages/curl:8.12.1 --schedule="*/2 * * * *" -- curl -fsS http://demo-app:8080/health
