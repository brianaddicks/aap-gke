#!/bin/bash
kubectl delete pod -l=app.kubernetes.io/managed-by=eda-operator
kubectl delete pod -l=app.kubernetes.io/managed-by=automationcontroller-operator
kubectl delete pod -l=app.kubernetes.io/managed-by=automationhub-operator
kubectl delete pod -l=app.kubernetes.io/managed-by=aap-operator
