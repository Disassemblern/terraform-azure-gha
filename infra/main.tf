terraform {
  required_version = "~> 1.17"

  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 5.14"
    }
  }

  # storage_account_name is passed at init:
  #   terraform init -backend-config=storage_account_name=<from bootstrap>
  backend "azurerm" {
    resource_group_name = "rg-tfstate"
    container_name      = "tfstate"
    key                 = "site.tfstate"
  }
}

# Auth comes from ARM_* env vars in CI (OIDC) or `az login` locally.
provider "azurerm" {
  features {}
}

data "azurerm_client_config" "current" {}

resource "azurerm_resource_group" "site" {
  name     = "rg-terraform-azure-gha"
  location = var.location
}

resource "azurerm_storage_account" "site" {
  # Globally unique, stable per subscription.
  name                     = "stsite${substr(sha1(data.azurerm_client_config.current.subscription_id), 0, 8)}"
  resource_group_name      = azurerm_resource_group.site.name
  location                 = azurerm_resource_group.site.location
  account_tier             = "Standard"
  account_replication_type = "LRS"
}

resource "azurerm_storage_account_static_website" "site" {
  storage_account_id = azurerm_storage_account.site.id
  index_document     = "index.html"
}

resource "azurerm_storage_blob" "index" {
  name                 = "index.html"
  storage_container_id = "${azurerm_storage_account.site.id}/blobServices/default/containers/$web"
  type                 = "Block"
  content_type         = "text/html"
  source               = "${path.module}/site/index.html"
  content_md5          = filemd5("${path.module}/site/index.html") # re-upload on change

  depends_on = [azurerm_storage_account_static_website.site] # creates the $web container
}
