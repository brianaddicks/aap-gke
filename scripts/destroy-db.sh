#!/bin/bash
gcloud sql databases delete controller --instance=${GKE_DB_INSTANCE} --quiet
gcloud sql databases delete hub --instance=${GKE_DB_INSTANCE} --quiet
gcloud sql databases delete eda --instance=${GKE_DB_INSTANCE} --quiet
gcloud sql databases delete platform --instance=${GKE_DB_INSTANCE} --quiet
