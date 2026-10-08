# Utiliza imagem base oficial minimalista com versão fixa (redução da superfície de ataque)
FROM node:20-alpine

# Define o diretório de trabalho da aplicação
WORKDIR /app

# Define ambiente de produção
ENV NODE_ENV=production

# Copia os arquivos da aplicação definindo o usuário node como proprietário
COPY --chown=node:node app/ ./app/

# Aplica o princípio do menor privilégio executando com usuário não-root nativo
USER node

# Documenta a porta que a aplicação utiliza
EXPOSE 3000

# Executa a aplicação
CMD ["node", "app/server.js"]