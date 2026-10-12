// Blue-green delivery pipeline for the "shop" stack.
// Required Jenkins credentials:
//   registry-creds  (Username/Password)  -> docker registry login
//   shop-env-file   (Secret file)        -> contents of .env (see .env.example)
// NOTE: do NOT enable "Wipe workspace / Clean before checkout" on this job: the workspace
//       holds the deployment state (.deploy.env, deploy.log, nginx/active_upstream.conf).

pipeline {
  agent any

  options {
    disableConcurrentBuilds()          // one deploy at a time: state files are shared
    timeout(time: 45, unit: 'MINUTES')
    buildDiscarder(logRotator(numToKeepStr: '20'))
    timestamps()
  }

  triggers { pollSCM('H/5 * * * *') }  // or use a GitHub/GitLab webhook instead

  parameters {
    choice(name: 'ENVIRONMENT', choices: ['dev', 'staging', 'prod'],
           description: 'Target environment (prod requires manual approval before switching traffic)')
    string(name: 'IMAGE_TAG', defaultValue: '',
           description: 'Image tag to build/deploy. Blank = Jenkins build number')
    booleanParam(name: 'RUN_INTEGRATION_TESTS', defaultValue: true,
                 description: 'Spin up API + Postgres and run integration tests')
    booleanParam(name: 'ROLLBACK', defaultValue: false,
                 description: 'Skip the release and just flip traffic back to the previous color')
  }

  environment {
    REGISTRY     = 'localhost:5000'
    TAG          = "${params.IMAGE_TAG ?: env.BUILD_NUMBER}"
    DEPLOY_ENV   = "${params.ENVIRONMENT}"
    DEPLOY_ACTOR = "jenkins-build-${env.BUILD_NUMBER}"
  }

  stages {

    stage('Checkout') {
      steps {
        checkout scm
        script {
          env.GIT_SHA = sh(returnStdout: true, script: 'git rev-parse --short HEAD').trim()
          currentBuild.displayName = "#${env.BUILD_NUMBER} ${env.TAG} (${env.GIT_SHA})"
        }
      }
    }

    stage('Prepare Config') {
      steps {
        withCredentials([file(credentialsId: 'shop-env-file', variable: 'ENV_FILE')]) {
          sh 'cp "$ENV_FILE" .env && chmod 600 .env'
        }
      }
    }

    stage('Manual Rollback') {
      when { expression { params.ROLLBACK } }
      steps {
        sh 'scripts/switch.sh status'
        sh 'scripts/switch.sh rollback'
        sh 'scripts/switch.sh status'
      }
    }

    stage('Release') {
      when { expression { !params.ROLLBACK } }
      stages {

        stage('Static Analysis') {
          steps {
            sh 'docker run --rm -i hadolint/hadolint hadolint --failure-threshold warning - < api/Dockerfile'
            sh 'docker run --rm -i hadolint/hadolint hadolint --failure-threshold warning - < worker/Dockerfile'
            sh 'docker build --target test -t shop-api-test:$TAG api'
            sh 'docker run --rm shop-api-test:$TAG flake8 .'
          }
        }

        stage('Unit Tests') {
          steps {
            sh '''
              rm -rf api/reports && mkdir -p api/reports
              docker run --rm -v "$PWD/api/reports:/app/reports" shop-api-test:$TAG \
                pytest tests/unit --junitxml=reports/report.xml \
                       --cov=app --cov-report=xml:reports/coverage.xml --cov-report=term
            '''
          }
          post {
            always {
              junit allowEmptyResults: true, testResults: 'api/reports/report.xml'
              archiveArtifacts artifacts: 'api/reports/coverage.xml', allowEmptyArchive: true
            }
          }
        }

        stage('Build Images') {
          steps {
            sh '''
              docker build --target runtime \
                --build-arg APP_VERSION=$TAG --build-arg GIT_COMMIT=$GIT_SHA \
                -t $REGISTRY/shop-api:$TAG api
              docker build -t $REGISTRY/shop-worker:$TAG worker
            '''
          }
        }

        stage('Integration Tests') {
          when { expression { params.RUN_INTEGRATION_TESTS } }
          steps {
            sh 'docker compose -f docker-compose.test.yml up --abort-on-container-exit --exit-code-from tests'
          }
          post {
            always {
              sh 'docker compose -f docker-compose.test.yml down -v --remove-orphans || true'
            }
          }
        }

        stage('Vulnerability Scan') {
          steps {
            sh '''
              for img in shop-api shop-worker; do
                docker run --rm \
                  -v /var/run/docker.sock:/var/run/docker.sock \
                  -v trivy-cache:/root/.cache \
                  aquasec/trivy:latest image \
                  --exit-code 1 --severity HIGH,CRITICAL --ignore-unfixed \
                  $REGISTRY/$img:$TAG
              done
            '''
          }
        }

        stage('Push') {
          steps {
            withCredentials([usernamePassword(credentialsId: 'registry-creds',
                             usernameVariable: 'REG_USER', passwordVariable: 'REG_PASS')]) {
              sh '''
                echo "$REG_PASS" | docker login "$REGISTRY" -u "$REG_USER" --password-stdin
                docker push $REGISTRY/shop-api:$TAG
                docker push $REGISTRY/shop-worker:$TAG
              '''
            }
          }
        }

        stage('Deploy Idle Color') {
          steps {
            sh 'scripts/switch.sh deploy-idle $TAG'
          }
        }

        stage('Approval') {
          when { expression { params.ENVIRONMENT == 'prod' } }
          steps {
            timeout(time: 30, unit: 'MINUTES') {
              input message: "Switch PRODUCTION traffic to version ${env.TAG}?", ok: 'Switch traffic'
            }
          }
        }

        stage('Switch Traffic') {
          steps {
            sh 'scripts/switch.sh switch'
            script { env.SWITCHED = 'true' }
          }
        }

        stage('Post-Deploy Verification') {
          steps {
            sh 'scripts/switch.sh verify $TAG'
          }
        }

        stage('Update Worker') {
          steps {
            sh 'scripts/switch.sh deploy-worker $TAG'
          }
        }
      }
    }
  }

  post {
    failure {
      script {
        if (env.SWITCHED == 'true') {
          echo 'Failure AFTER traffic switch -> automatic rollback to previous color'
          sh 'scripts/switch.sh rollback'
        }
        echo "DEPLOY FAILED: tag=${env.TAG} env=${env.DEPLOY_ENV}"
      }
    }
    success {
      echo "DEPLOY OK: tag=${env.TAG} env=${env.DEPLOY_ENV}"
    }
    always {
      sh 'docker rmi shop-api-test:$TAG || true'
      sh 'docker image prune -f || true'
    }
  }
}
