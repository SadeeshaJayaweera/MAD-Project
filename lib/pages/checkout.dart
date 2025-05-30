import 'package:flutter/material.dart';
import 'package:thriftale/models/product_model.dart';
import 'package:thriftale/models/payment_method_model.dart';
import 'package:thriftale/pages/success.dart';
import 'package:thriftale/pages/cart.dart';
import 'package:thriftale/pages/payment_methods_page.dart';
import 'package:thriftale/pages/add_payment_method_page.dart';
import 'package:thriftale/services/cart_service.dart';
import 'package:thriftale/services/checkout_service.dart';
import 'package:thriftale/services/product_service.dart';
import 'package:thriftale/services/payment_service.dart';
import 'package:thriftale/utils/appColors.dart';
import 'package:thriftale/utils/lable_texts.dart';
import 'package:thriftale/utils/pageNavigations.dart';
import 'package:thriftale/utils/paragraph_texts.dart';
import 'package:thriftale/widgets/custom_button.dart';
import 'package:thriftale/widgets/custom_text.dart';
import 'package:firebase_auth/firebase_auth.dart';

class Checkout extends StatefulWidget {
  const Checkout({super.key});

  @override
  State<Checkout> createState() => _CheckoutState();
}

class _CheckoutState extends State<Checkout> {
  final CheckoutService _checkoutService = CheckoutService();
  final CartService _cartService = CartService();
  final ProductService _productService = ProductService();
  final PaymentService _paymentService = PaymentService();
  final String userId = FirebaseAuth.instance.currentUser!.uid;

  bool _isLoading = false;
  Map<String, dynamic>? _orderSummary;
  List<Map<String, dynamic>> _cartItems = [];
  List<Product?> _products = [];
  PaymentMethod? _selectedPaymentMethod;
  bool _hasPaymentMethods = false;

  // Default address (in real app, this would be selected by user)
  final Map<String, dynamic> _defaultAddress = {
    'name': 'Jane Doe',
    'addressLine1': '3 Newbridge Court',
    'addressLine2': 'Chino Hills, CA 91709, United States',
    'isDefault': true,
  };

  @override
  void initState() {
    super.initState();
    _loadCheckoutData();
  }

  Future<void> _loadCheckoutData() async {
    setState(() {
      _isLoading = true;
    });

    try {
      // Get cart items
      final cartStream = _cartService.getCartItems(userId);
      final cartSnapshot = await cartStream.first;
      _cartItems = cartSnapshot;

      if (_cartItems.isNotEmpty) {
        // Load product details
        final productFutures = _cartItems
            .map((item) => _productService.getProductById(item['productId']));
        _products = await Future.wait(productFutures);

        // Calculate order summary
        _orderSummary = await _calculateOrderSummary();
      }

      // Load payment methods and check if any exist
      await _loadPaymentMethods();
    } catch (e) {
      _showErrorDialog('Failed to load checkout data: $e');
    } finally {
      setState(() {
        _isLoading = false;
      });
    }
  }

  Future<void> _loadPaymentMethods() async {
    try {
      // Get all payment methods
      final paymentMethodsStream = _paymentService.getPaymentMethods();
      final paymentMethods = await paymentMethodsStream.first;

      setState(() {
        _hasPaymentMethods = paymentMethods.isNotEmpty;
      });

      if (_hasPaymentMethods) {
        // Load default payment method
        _selectedPaymentMethod =
            await _paymentService.getDefaultPaymentMethod();
      } else {
        _selectedPaymentMethod = null;
      }
    } catch (e) {
      print('Error loading payment methods: $e');
      setState(() {
        _hasPaymentMethods = false;
        _selectedPaymentMethod = null;
      });
    }
  }

  Future<Map<String, dynamic>> _calculateOrderSummary() async {
    double subtotal = 0;
    double totalCO2 = 0;
    int itemsRescued = _products.length;

    for (Product? product in _products) {
      if (product != null) {
        subtotal += product.price;
        totalCO2 += product.co2Saved;
      }
    }

    return {
      'subtotal': subtotal,
      'deliveryFee': 0.0,
      'total': subtotal,
      'co2Saved': totalCO2,
      'itemsRescued': itemsRescued,
    };
  }

  Future<void> _processCheckout() async {
    if (_orderSummary == null || _cartItems.isEmpty) {
      _showErrorDialog('Cart is empty or order summary not loaded');
      return;
    }

    if (!_hasPaymentMethods || _selectedPaymentMethod == null) {
      _showErrorDialog('Please add a payment method to continue');
      return;
    }

    // Check authentication first
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) {
      _showErrorDialog('Please log in again to continue with checkout.');
      return;
    }

    setState(() {
      _isLoading = true;
    });

    try {
      print('Starting checkout process...'); // Debug log

      // Prepare cart items with product details for order
      List<Map<String, dynamic>> orderItems = [];
      for (int i = 0; i < _cartItems.length; i++) {
        final cartItem = _cartItems[i];
        final product = _products[i];
        if (product != null) {
          orderItems.add({
            'productId': cartItem['productId'],
            'productName': product.name,
            'price': product.price,
            'co2Saved': product.co2Saved,
            'imageUrl':
                product.imageUrls.isNotEmpty ? product.imageUrls.first : '',
            'location': product.location,
          });
        }
      }

      print('Order items prepared: ${orderItems.length} items'); // Debug log

      // Prepare payment method data for checkout
      final paymentMethodData = {
        'type': _selectedPaymentMethod!.type,
        'lastFourDigits': _selectedPaymentMethod!.lastFourDigits,
        'expiryMonth': _selectedPaymentMethod!.expiryMonth,
        'expiryYear': _selectedPaymentMethod!.expiryYear,
        'isDefault': _selectedPaymentMethod!.isDefault,
      };

      // Complete checkout process
      final result = await _checkoutService.completeCheckout(
        cartItems: orderItems,
        shippingAddress: _defaultAddress,
        paymentMethod: paymentMethodData,
        totalAmount: _orderSummary!['total'],
        totalCO2Saved: _orderSummary!['co2Saved'],
        itemsRescued: _orderSummary!['itemsRescued'],
      );

      print('Checkout result: $result'); // Debug log

      if (result['success']) {
        // Clear the cart after successful checkout
        print('Clearing cart after successful checkout...'); // Debug log
        await _cartService.clearCart(userId);
        print('Cart cleared successfully'); // Debug log

        // Navigate to success page with order details
        NavigationUtils.frontNavigation(
            context,
            Success(
              orderId: result['orderId'],
              totalAmount: _orderSummary!['total'],
              co2Saved: _orderSummary!['co2Saved'],
              itemsRescued: _orderSummary!['itemsRescued'],
            ));
      } else {
        String errorMessage =
            result['message'] ?? 'Checkout failed. Please try again.';

        // Show more specific error information if available
        if (result['error'] != null) {
          print('Detailed error: ${result['error']}'); // For debugging
        }

        _showErrorDialog(errorMessage);
      }
    } catch (e) {
      print('Checkout exception: $e'); // Debug log

      String errorMessage = 'Checkout failed. Please try again.';

      if (e.toString().contains('permission-denied')) {
        errorMessage =
            'Access denied. Please contact support or try logging in again.';
      } else if (e.toString().contains('network')) {
        errorMessage = 'Network error. Please check your internet connection.';
      } else if (e.toString().contains('User not authenticated')) {
        errorMessage = 'Session expired. Please log in again.';
      }

      _showErrorDialog(errorMessage);
    } finally {
      if (mounted) {
        setState(() {
          _isLoading = false;
        });
      }
    }
  }

  void _showErrorDialog(String message) {
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (context) => AlertDialog(
        title: Row(
          children: [
            Icon(Icons.error_outline, color: Colors.red, size: 24),
            SizedBox(width: 8),
            Text('Checkout Error'),
          ],
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(message),
            SizedBox(height: 16),
            Text(
              'If this problem persists, please contact support.',
              style: TextStyle(
                fontSize: 12,
                color: Colors.grey[600],
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: Text('OK'),
          ),
          if (message.toLowerCase().contains('log in') ||
              message.toLowerCase().contains('session'))
            TextButton(
              onPressed: () {
                Navigator.of(context).pop();
                // Navigate to login page
                // NavigationUtils.frontNavigation(context, LoginPage());
              },
              child: Text('Log In'),
            ),
        ],
      ),
    );
  }

  Widget _buildCardTypeIcon(String cardType) {
    switch (cardType.toLowerCase()) {
      case 'mastercard':
        return Container(
          width: 40,
          height: 25,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(4.0),
          ),
          child: Stack(
            children: [
              Positioned(
                left: 0,
                child: Container(
                  width: 20,
                  height: 20,
                  decoration: const BoxDecoration(
                    color: Color(0xFFEB001B),
                    shape: BoxShape.circle,
                  ),
                ),
              ),
              Positioned(
                left: 12,
                child: Container(
                  width: 20,
                  height: 20,
                  decoration: const BoxDecoration(
                    color: Color(0xFFF79E1B),
                    shape: BoxShape.circle,
                  ),
                ),
              ),
            ],
          ),
        );
      case 'visa':
        return Container(
          width: 40,
          height: 25,
          decoration: BoxDecoration(
            color: Colors.blue[700],
            borderRadius: BorderRadius.circular(4.0),
          ),
          child: Center(
            child: Text(
              'VISA',
              style: TextStyle(
                color: Colors.white,
                fontSize: 10,
                fontWeight: FontWeight.bold,
              ),
            ),
          ),
        );
      case 'amex':
      case 'american express':
        return Container(
          width: 40,
          height: 25,
          decoration: BoxDecoration(
            color: Colors.blue[900],
            borderRadius: BorderRadius.circular(4.0),
          ),
          child: Center(
            child: Text(
              'AMEX',
              style: TextStyle(
                color: Colors.white,
                fontSize: 8,
                fontWeight: FontWeight.bold,
              ),
            ),
          ),
        );
      default:
        return Icon(
          Icons.credit_card,
          color: Colors.grey[600],
          size: 24,
        );
    }
  }

  Widget _buildAddPaymentMethodSection() {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(16.0),
      margin: const EdgeInsets.only(top: 12.0),
      decoration: BoxDecoration(
        color: AppColors.white,
        borderRadius: BorderRadius.circular(8.0),
        border: Border.all(color: Colors.grey[300]!, width: 1),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(0.1),
            blurRadius: 8,
            offset: const Offset(0, 2),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              CustomText(
                text: 'Payment Method',
                color: AppColors.black,
                fontSize: ParagraphTexts.textFieldLable,
                fontWeight: FontWeight.w600,
              ),
            ],
          ),
          const SizedBox(height: 16.0),
          // Add Payment Method Button
          InkWell(
            onTap: () async {
              final result = await Navigator.of(context).push(
                MaterialPageRoute(
                  builder: (context) => const AddPaymentMethodPage(),
                ),
              );
              if (result == true) {
                // Reload payment methods after adding new one
                await _loadPaymentMethods();
                setState(() {});
              }
            },
            borderRadius: BorderRadius.circular(8),
            child: Container(
              width: double.infinity,
              padding: const EdgeInsets.symmetric(vertical: 16, horizontal: 20),
              decoration: BoxDecoration(
                color: const Color.fromARGB(255, 213, 167, 66).withOpacity(0.1),
                borderRadius: BorderRadius.circular(8),
                border: Border.all(
                  color: const Color.fromARGB(255, 213, 167, 66),
                  width: 1.5,
                ),
              ),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(
                    Icons.add_card,
                    color: const Color.fromARGB(255, 213, 167, 66),
                    size: 20,
                  ),
                  const SizedBox(width: 8),
                  CustomText(
                    text: 'Add Payment Method',
                    color: const Color.fromARGB(255, 213, 167, 66),
                    fontSize: ParagraphTexts.textFieldLable,
                    fontWeight: FontWeight.w600,
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 12),
          Center(
            child: CustomText(
              text: 'You need to add a payment method to proceed',
              color: Colors.grey[600]!,
              fontSize: ParagraphTexts.normalParagraph * 0.9,
              fontWeight: FontWeight.w400,
              textAlign: TextAlign.center,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildExistingPaymentMethodSection() {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(16.0),
      margin: const EdgeInsets.only(top: 12.0),
      decoration: BoxDecoration(
        color: AppColors.white,
        borderRadius: BorderRadius.circular(8.0),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(0.1),
            blurRadius: 8,
            offset: const Offset(0, 2),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              CustomText(
                text: 'Payment Method',
                color: AppColors.black,
                fontSize: ParagraphTexts.textFieldLable,
                fontWeight: FontWeight.w600,
              ),
              GestureDetector(
                onTap: () async {
                  final result = await Navigator.of(context).push(
                    MaterialPageRoute(
                      builder: (context) => const PaymentMethodsPage(),
                    ),
                  );
                  if (result == true) {
                    // Reload payment method after changes
                    await _loadPaymentMethods();
                    setState(() {});
                  }
                },
                child: CustomText(
                  text: 'Change',
                  color: Colors.red,
                  fontSize: ParagraphTexts.textFieldLable,
                  fontWeight: FontWeight.w500,
                ),
              ),
            ],
          ),
          const SizedBox(height: 16.0),
          // Payment Method Display
          if (_selectedPaymentMethod != null) ...[
            Row(
              children: [
                // Card type icon
                _buildCardTypeIcon(_selectedPaymentMethod!.type),
                const SizedBox(width: 12.0),
                Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    CustomText(
                      text: _selectedPaymentMethod!.maskedCardNumber,
                      color: AppColors.black,
                      fontSize: ParagraphTexts.textFieldLable,
                      fontWeight: FontWeight.w500,
                    ),
                    const SizedBox(height: 2),
                    CustomText(
                      text: _selectedPaymentMethod!.cardHolderName,
                      color: Colors.grey[600]!,
                      fontSize: ParagraphTexts.normalParagraph,
                      fontWeight: FontWeight.w400,
                    ),
                  ],
                ),
              ],
            ),
          ] else ...[
            // Fallback when payment method is null but hasPaymentMethods is true
            Row(
              children: [
                _buildCardTypeIcon('visa'),
                const SizedBox(width: 12.0),
                Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    CustomText(
                      text: '**** **** **** ****',
                      color: AppColors.black,
                      fontSize: ParagraphTexts.textFieldLable,
                      fontWeight: FontWeight.w500,
                    ),
                    const SizedBox(height: 2),
                    CustomText(
                      text: 'Loading payment method...',
                      color: Colors.grey[600]!,
                      fontSize: ParagraphTexts.normalParagraph,
                      fontWeight: FontWeight.w400,
                    ),
                  ],
                ),
              ],
            ),
          ],
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color.fromARGB(255, 246, 246, 246),
      body: SafeArea(
        child: Column(
          children: [
            // Fixed header with working back button
            Padding(
              padding: const EdgeInsets.all(16.0),
              child: Row(
                children: [
                  InkWell(
                    onTap: () {
                      NavigationUtils.frontNavigation(context, const Cart());
                    },
                    borderRadius: BorderRadius.circular(20),
                    child: Container(
                      width: 40,
                      height: 40,
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(20),
                        color: AppColors.CardBg,
                      ),
                      child: const Icon(
                        Icons.arrow_back_ios_new,
                        color: Colors.black,
                        size: 18,
                      ),
                    ),
                  ),
                  const SizedBox(width: 10),
                  CustomText(
                    text: 'Checkout',
                    color: AppColors.black,
                    fontSize: LableTexts.subLable,
                    fontWeight: FontWeight.w600,
                  ),
                ],
              ),
            ),

            // Content
            Expanded(
              child: _isLoading
                  ? const Center(child: CircularProgressIndicator())
                  : _orderSummary == null
                      ? const Center(
                          child: Text('Failed to load checkout data'))
                      : SingleChildScrollView(
                          physics: const AlwaysScrollableScrollPhysics(),
                          child: Padding(
                            padding:
                                const EdgeInsets.symmetric(horizontal: 16.0),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                const SizedBox(height: 10),

                                // Shipping Address Section
                                CustomText(
                                  text: 'Shipping address',
                                  color: AppColors.black,
                                  fontSize: ParagraphTexts.textFieldLable,
                                  fontWeight: FontWeight.w600,
                                ),
                                Container(
                                  width: double.infinity,
                                  padding: const EdgeInsets.all(16.0),
                                  margin: const EdgeInsets.only(top: 12.0),
                                  decoration: BoxDecoration(
                                    color: AppColors.white,
                                    borderRadius: BorderRadius.circular(8.0),
                                    boxShadow: [
                                      BoxShadow(
                                        color: Colors.black.withOpacity(0.1),
                                        blurRadius: 8,
                                        offset: const Offset(0, 2),
                                      ),
                                    ],
                                  ),
                                  child: Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      Row(
                                        mainAxisAlignment:
                                            MainAxisAlignment.spaceBetween,
                                        children: [
                                          CustomText(
                                            text: _defaultAddress['name'],
                                            color: AppColors.black,
                                            fontSize:
                                                ParagraphTexts.textFieldLable,
                                            fontWeight: FontWeight.w600,
                                          ),
                                          GestureDetector(
                                            onTap: () {
                                              // Handle change address action
                                              print('Change address tapped');
                                            },
                                            child: CustomText(
                                              text: 'Change',
                                              color: Colors.red,
                                              fontSize:
                                                  ParagraphTexts.textFieldLable,
                                              fontWeight: FontWeight.w500,
                                            ),
                                          ),
                                        ],
                                      ),
                                      const SizedBox(height: 8.0),
                                      CustomText(
                                        text: _defaultAddress['addressLine1'],
                                        color: AppColors.black.withOpacity(0.7),
                                        fontSize:
                                            ParagraphTexts.textFieldLable * 0.9,
                                        fontWeight: FontWeight.w400,
                                      ),
                                      const SizedBox(height: 4.0),
                                      CustomText(
                                        text: _defaultAddress['addressLine2'],
                                        color: AppColors.black.withOpacity(0.7),
                                        fontSize:
                                            ParagraphTexts.textFieldLable * 0.9,
                                        fontWeight: FontWeight.w400,
                                      ),
                                    ],
                                  ),
                                ),

                                const SizedBox(height: 20),

                                // Payment Section - Conditional Display
                                CustomText(
                                  text: 'Payment',
                                  color: AppColors.black,
                                  fontSize: ParagraphTexts.textFieldLable,
                                  fontWeight: FontWeight.w600,
                                ),

                                // Show different sections based on payment method availability
                                _hasPaymentMethods
                                    ? _buildExistingPaymentMethodSection()
                                    : _buildAddPaymentMethodSection(),

                                const SizedBox(height: 30),

                                // Order Summary Section
                                _buildSummaryRow('Order:',
                                    'Rs. ${_orderSummary!['subtotal'].toStringAsFixed(2)}'),
                                const SizedBox(height: 10),
                                _buildSummaryRow('Delivery:', 'Free'),
                                const SizedBox(height: 10),
                                _buildSummaryRow('Total:',
                                    'Rs. ${_orderSummary!['total'].toStringAsFixed(2)}'),
                                const SizedBox(height: 15),
                                Container(
                                  height: 1,
                                  color: Colors.grey.withOpacity(0.3),
                                ),
                                const SizedBox(height: 15),
                                _buildSummaryRow('Carbon Saved:',
                                    '${_orderSummary!['co2Saved'].toStringAsFixed(1)} kg'),
                                const SizedBox(height: 10),
                                _buildSummaryRow(
                                    'Items Rescued from Landfills:',
                                    '${_orderSummary!['itemsRescued']} items'),

                                const SizedBox(height: 80),

                                // Submit Button - Enhanced with better loading state and conditional enabling
                                CustomButton(
                                  text: _isLoading
                                      ? 'Processing...'
                                      : !_hasPaymentMethods
                                          ? 'Add Payment Method to Continue'
                                          : 'Submit Order',
                                  backgroundColor: _isLoading
                                      ? Colors.grey
                                      : !_hasPaymentMethods
                                          ? Colors.grey[400]!
                                          : const Color.fromARGB(
                                              255, 213, 167, 66),
                                  textColor: AppColors.white,
                                  textWeight: FontWeight.w600,
                                  textSize: ParagraphTexts.textFieldLable,
                                  width: double.infinity,
                                  height: 52,
                                  borderRadius: 50,
                                  onPressed: _isLoading
                                      ? () {
                                          // Do nothing when loading - button is disabled
                                        }
                                      : !_hasPaymentMethods
                                          ? () async {
                                              // Navigate to add payment method
                                              final result =
                                                  await Navigator.of(context)
                                                      .push(
                                                MaterialPageRoute(
                                                  builder: (context) =>
                                                      const AddPaymentMethodPage(),
                                                ),
                                              );
                                              if (result == true) {
                                                await _loadPaymentMethods();
                                                setState(() {});
                                              }
                                            }
                                          : _processCheckout,
                                ),

                                const SizedBox(height: 30),
                              ],
                            ),
                          ),
                        ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildSummaryRow(String label, String value) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Flexible(
          flex: 2,
          child: CustomText(
            text: label,
            color: AppColors.black,
            fontSize: ParagraphTexts.normalParagraph,
            fontWeight: FontWeight.normal,
          ),
        ),
        const SizedBox(width: 8),
        Flexible(
          flex: 1,
          child: CustomText(
            text: value,
            color: AppColors.black,
            fontSize: ParagraphTexts.normalParagraph,
            fontWeight: FontWeight.w600,
            textAlign: TextAlign.right,
          ),
        ),
      ],
    );
  }
}
