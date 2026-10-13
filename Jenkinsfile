pipeline {
    agent any
    
    environment {
        REGISTRY = 'localhost:5000'
        TAG = "${env.BUILD_NUMBER}"
    }

    options {
        timeout(time: 45, unit: 'MINUTES')
        timestamps()
    }

    stages {
        stage('Checkout') {
            steps {
                checkout scm
                script {
                    env.GIT_COMMIT_SHORT = sh(script: 'git rev-parse --short HEAD', returnStdout: true).trim()
                }
            }
        }

        stage('Prepare Config') {
            steps {
                withCredentials([file(credentialsId: 'env-file', variable: 'ENV_FILE')]) {
                    sh 'cp ${ENV_FILE} .env'
                    sh 'chmod 600 .env'
                }
            }
        }

        stage('Static Analysis') {
            steps {
                sh 'docker run --rm -i hadolint/hadolint hadolint --failure-threshold warning - < api/Dockerfile || true'
                sh 'docker run --rm -i hadolint/hadolint hadolint --failure-threshold warning - < worker/Dockerfile || true'
                
                // Build the test stage image specifically for unit/integration tests
                sh "docker build --target test -t shop-api-test:${env.TAG} api"
                
                // Run flake8 linter inside the container
                sh "docker run --rm shop-api-test:${env.TAG} flake8 ."
            }
        }

        stage('Unit Tests') {
    steps {
        sh 'rm -rf api/reports'
        sh 'mkdir -p api/reports'
        sh "docker run --rm -v ${WORKSPACE}/api/reports:/app/reports shop-api-test:${env.TAG} pytest tests/unit --junitxml=reports/report.xml --cov=app --cov-report=xml:reports/coverage.xml --cov-report=term"
        sh 'chmod -R 777 api/reports'
    }
    post {
        always {
            junit 'api/reports/report.xml'
            archiveArtifacts artifacts: 'api/reports/coverage.xml', allowEmptyArchive: true
        }
    }
}

        stage('Build Images') {
            steps {
                sh "docker build --target runtime --build-arg APP_VERSION=${env.TAG} --build-arg GIT_COMMIT=${env.GIT_COMMIT_SHORT} -t ${env.REGISTRY}/shop-api:${env.TAG} api"
                sh "docker build -t ${env.REGISTRY}/shop-worker:${env.TAG} worker"
            }
        }

        stage('Integration Tests') {
            steps {
                script {
                    // Fix potential CLI plugin permission issues on Jenkins agents
                    sh 'chmod +x /usr/local/lib/docker/cli-plugins/docker-compose || true'
                }
                sh "docker compose -f docker-compose.test.yml up --abort-on-container-exit --exit-code-from tests"
            }
            post {
                always {
                    sh "docker compose -f docker-compose.test.yml down -v --remove-orphans || true"
                }
            }
        }
    }

    post {
        failure {
            echo "DEPLOY FAILED: tag=${env.TAG} env=dev"
        }
        always {
            sh "docker rmi shop-api-test:${env.TAG} || true"
            sh 'docker image prune -f || true'
        }
    }
}